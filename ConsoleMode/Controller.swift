import AppKit
import GameController
import CoreHaptics

protocol ControllerDelegate: AnyObject {
    /// Any deliberate controller input (button, stick, touchpad)
    func controllerActivity()
    func toggleKeyboard()
    var keyboardVisible: Bool { get }
    /// While the keyboard is open, buttons act like a PS5 keyboard. Return true if handled.
    func keyboardButton(_ button: PadButton, down: Bool) -> Bool
    func controllerChanged()
}

/// Reads the DualSense directly and turns it into Mac input.
final class ControllerManager {
    weak var delegate: ControllerDelegate?
    private let settings = AppSettings.shared
    private let out = Output.shared

    private(set) var controller: GCController?
    private var timer: Timer?
    private var lastTick = Date()
    private var hapticEngine: CHHapticEngine?

    // Button state
    private struct Press {
        var start: Date
        var binding: ButtonBinding
        var pressFired = false
        var holdFired = false
        var nextRepeat: Date?
        var handledByKeyboard = false
    }
    private var down: [PadButton: Press] = [:]
    private var quickMenuHeld: Bool { down[.l2].map { !$0.handledByKeyboard } ?? false }

    // Touchpad state
    private var touchLast: CGPoint?
    private var touchStart = Date()
    private var touchTravel: CGFloat = 0
    private var touchClicked = false

    private let holdTime: TimeInterval = 0.5

    var name: String { controller?.vendorName ?? "No controller" }
    var batteryLevel: Float? { controller?.battery.map { $0.batteryLevel } }
    var charging: Bool { controller?.battery?.batteryState == .charging }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
            [weak self] note in
            if let c = note.object as? GCController { self?.attach(c) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
            [weak self] note in
            guard let self, let c = note.object as? GCController, c === self.controller else { return }
            self.releaseAll()
            self.controller = nil
            self.hapticEngine = nil
            self.attach(GCController.controllers().first { $0.extendedGamepad != nil })
        }
        attach(GCController.controllers().first { $0.extendedGamepad != nil })
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func attach(_ c: GCController?) {
        guard let c, c.extendedGamepad != nil else { delegate?.controllerChanged(); return }
        controller = c
        // Keep macOS from grabbing the PS and Create buttons for its own shortcuts
        if let pad = c.extendedGamepad {
            pad.buttonHome?.preferredSystemGestureState = .disabled
            pad.buttonOptions?.preferredSystemGestureState = .disabled
        }
        settings.autoSelect(for: style)
        applyLight()
        if let engine = c.haptics?.createEngine(withLocality: .default) {
            engine.isAutoShutdownEnabled = true
            hapticEngine = engine
        }
        delegate?.controllerChanged()
    }

    /// PlayStation or Xbox, from the kind of controller connected
    var style: ControllerStyle {
        guard let pad = controller?.extendedGamepad else { return settings.activeProfile.style }
        if pad is GCDualSenseGamepad || pad is GCDualShockGamepad { return .playstation }
        if pad is GCXboxGamepad { return .xbox }
        return settings.activeProfile.style
    }

    private var lightTimer: Timer?
    private var partyHue: Double = 0
    private var lastLight: (Float, Float, Float)?

    /// Light bar: a solid color, a slow rainbow (Party), or the charge level (Battery)
    func applyLight() {
        lightTimer?.invalidate()
        lightTimer = nil
        lastLight = nil
        guard controller?.light != nil else { return }
        switch settings.data.lightMode {
        case .solid:
            let d = settings.data
            setLight(Float(d.lightRed), Float(d.lightGreen), Float(d.lightBlue))
        case .party:
            let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.partyHue = (self.partyHue + 0.012).truncatingRemainder(dividingBy: 1)
                let c = NSColor(hue: self.partyHue, saturation: 1, brightness: 1, alpha: 1)
                self.setLight(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
            }
            RunLoop.main.add(t, forMode: .common)
            lightTimer = t
        case .battery:
            showBattery()
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.showBattery() }
            RunLoop.main.add(t, forMode: .common)
            lightTimer = t
        }
    }

    /// Green when full, yellow in the middle, red when low; pulses while charging
    private func showBattery() {
        guard let level = batteryLevel else { setLight(1, 1, 1); return }
        let hue = Double(max(0, min(1, level))) * 0.33   // 0 = red … 0.33 = green
        var brightness = 1.0
        if charging {
            let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            brightness = 0.35 + 0.65 * (0.5 + 0.5 * sin(phase * 2 * .pi))
        }
        let c = NSColor(hue: hue, saturation: 1, brightness: brightness, alpha: 1)
        setLight(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }

    private func setLight(_ r: Float, _ g: Float, _ b: Float) {
        if let l = lastLight, abs(l.0 - r) + abs(l.1 - g) + abs(l.2 - b) < 0.01 { return }
        lastLight = (r, g, b)
        controller?.light?.color = GCColor(red: r, green: g, blue: b)
    }

    func rumble(_ intensity: Float = 0.6) {
        guard settings.data.rumble, let engine = hapticEngine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
        ], relativeTime: 0)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []) else { return }
        // Start asynchronously so waking the haptics never stalls the pointer
        engine.start { [weak engine] error in
            guard error == nil, let engine else { return }
            try? engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        }
    }

    // MARK: Main loop

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.05)
        lastTick = now
        guard settings.data.enabled, let pad = controller?.extendedGamepad else {
            if !down.isEmpty { releaseAll() }
            touchLast = nil
            return
        }

        readButtons(pad, now: now)
        moveWithSticks(pad, dt: dt)
        readTouchpad(pad, now: now)
    }

    private func isDown(_ b: PadButton, _ pad: GCExtendedGamepad) -> Bool {
        switch b {
        case .cross: return pad.buttonA.isPressed
        case .circle: return pad.buttonB.isPressed
        case .square: return pad.buttonX.isPressed
        case .triangle: return pad.buttonY.isPressed
        case .l1: return pad.leftShoulder.isPressed
        case .r1: return pad.rightShoulder.isPressed
        // Separate press/release thresholds so a half-pulled trigger can't flicker
        case .l2: return pad.leftTrigger.value > (down[.l2] == nil ? 0.45 : 0.25)
        case .r2: return pad.rightTrigger.value > (down[.r2] == nil ? 0.45 : 0.25)
        case .up: return pad.dpad.up.isPressed
        case .down: return pad.dpad.down.isPressed
        case .left: return pad.dpad.left.isPressed
        case .right: return pad.dpad.right.isPressed
        case .options: return pad.buttonMenu.isPressed
        case .create: return pad.buttonOptions?.isPressed ?? false
        case .ps: return pad.buttonHome?.isPressed ?? false
        case .l3: return pad.leftThumbstickButton?.isPressed ?? false
        case .r3: return pad.rightThumbstickButton?.isPressed ?? false
        case .touchpad:
            if let ds = pad as? GCDualSenseGamepad { return ds.touchpadButton.isPressed }
            if let ds4 = pad as? GCDualShockGamepad { return ds4.touchpadButton.isPressed }
            return false
        }
    }

    private func readButtons(_ pad: GCExtendedGamepad, now: Date) {
        for b in PadButton.allCases {
            let pressed = isDown(b, pad)
            if pressed, down[b] == nil {
                buttonDown(b, now: now)
            } else if pressed, var p = down[b] {
                buttonHeld(b, &p, now: now)
                down[b] = p
            } else if !pressed, let p = down[b] {
                down[b] = nil
                buttonUp(b, p)
            }
        }
    }

    private func bindingFor(_ b: PadButton) -> ButtonBinding {
        if b == .touchpad, isTwoFingerTouch() { return ButtonBinding(press: Action(kind: .rightClick)) }
        if quickMenuHeld, b != .l2 {
            let q = settings.binding(for: b, quickMenu: true)
            if q.press.kind != .none || q.hold.kind != .none { return q }
        }
        return settings.binding(for: b, quickMenu: false)
    }

    private func buttonDown(_ b: PadButton, now: Date) {
        if b == .touchpad { touchClicked = true }
        delegate?.controllerActivity()
        var p = Press(start: now, binding: b == .l2 ? ButtonBinding(press: .none) : bindingFor(b))
        if delegate?.keyboardVisible == true, delegate?.keyboardButton(b, down: true) == true {
            p.handledByKeyboard = true
            down[b] = p
            return
        }
        if p.binding.hold.kind == .none {
            perform(p.binding.press, phase: .down)
            p.pressFired = true
            if p.binding.press.kind.repeats { p.nextRepeat = now.addingTimeInterval(0.4) }
        }
        down[b] = p
    }

    private func buttonHeld(_ b: PadButton, _ p: inout Press, now: Date) {
        if p.handledByKeyboard { return }
        if !p.pressFired, !p.holdFired, p.binding.hold.kind != .none, now.timeIntervalSince(p.start) >= holdTime {
            perform(p.binding.hold, phase: .tap)
            p.holdFired = true
            rumble(0.8)
        }
        if p.pressFired, let next = p.nextRepeat, now >= next {
            perform(p.binding.press, phase: .tap)
            p.nextRepeat = now.addingTimeInterval(0.07)
        }
    }

    private func buttonUp(_ b: PadButton, _ p: Press) {
        if p.handledByKeyboard {
            _ = delegate?.keyboardButton(b, down: false)
            return
        }
        if p.pressFired {
            perform(p.binding.press, phase: .up)
        } else if !p.holdFired {
            perform(p.binding.press, phase: .tap)
        }
    }

    private func releaseAll() {
        for (_, p) in down where p.pressFired && !p.handledByKeyboard { perform(p.binding.press, phase: .up) }
        down.removeAll()
        touchLast = nil
    }

    // MARK: Performing actions

    enum Phase { case down, up, tap }

    func perform(_ action: Action, phase: Phase) {
        let isStart = phase == .down || phase == .tap
        switch action.kind {
        case .none:
            return
        case .leftClick:
            if phase == .down || phase == .tap { out.leftButton(down: true); rumble(0.4) }
            if phase == .up || phase == .tap { out.leftButton(down: false) }
        case .rightClick:
            if isStart { out.rightClick(); rumble(0.4) }
        case .middleClick:
            if isStart { out.middleClick() }
        case .keyboard:
            if isStart { delegate?.toggleKeyboard() }
        case .launchpad:
            if isStart {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.apps.launcher") != nil {
                    out.openApp(bundleID: "com.apple.apps.launcher")
                } else {
                    out.openApp(bundleID: "com.apple.launchpad.launcher")
                }
            }
        case .finder:
            if isStart { out.openApp(bundleID: "com.apple.finder") }
        case .lastApp:
            if isStart {
                out.key(KeyShortcut(keyCode: 55, command: true), down: true)
                out.tap(KeyShortcut(keyCode: 48, command: true))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [out] in
                    out.key(KeyShortcut(keyCode: 55), down: false)
                }
            }
        case .appSwitcher:
            // Hold the button to keep the app switcher open; let go to pick
            if phase == .down || phase == .tap {
                out.key(KeyShortcut(keyCode: 55, command: true), down: true)
                out.tap(KeyShortcut(keyCode: 48, command: true))
            }
            if phase == .up || phase == .tap { out.key(KeyShortcut(keyCode: 55), down: false) }
        case .playPause: if isStart { out.media(.play) }
        case .nextTrack: if isStart { out.media(.next) }
        case .previousTrack: if isStart { out.media(.previous) }
        case .volumeUp: if isStart { out.media(.volumeUp) }
        case .volumeDown: if isStart { out.media(.volumeDown) }
        case .mute: if isStart { out.media(.mute) }
        case .brightnessUp: if isStart { out.media(.brightnessUp) }
        case .brightnessDown: if isStart { out.media(.brightnessDown) }
        default:
            guard let s = action.kind == .shortcut ? action.custom : action.kind.shortcut else { return }
            switch phase {
            case .down: out.key(s, down: true)
            case .up: out.key(s, down: false)
            case .tap: out.tap(s)
            }
        }
    }

    // MARK: Sticks

    private func shaped(_ x: Float, _ y: Float, deadzone: Float, exponent: Double) -> (CGFloat, CGFloat)? {
        let m = hypot(x, y)
        guard m > deadzone else { return nil }
        let norm = min(1, (m - deadzone) / (1 - deadzone))
        let curved = CGFloat(pow(Double(norm), exponent))
        return (CGFloat(x / m) * curved, CGFloat(y / m) * curved)
    }

    private func moveWithSticks(_ pad: GCExtendedGamepad, dt: TimeInterval) {
        let d = settings.data
        // Left stick: pointer
        if let (vx, vy) = shaped(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
                                 deadzone: 0.12, exponent: 1 + d.stickAcceleration * 2) {
            delegate?.controllerActivity()
            let speed = CGFloat(250 + d.stickSpeed * 2250) * CGFloat(dt)
            out.movePointer(dx: vx * speed, dy: -vy * speed)
        }
        // Right stick: scroll
        if let (vx, vy) = shaped(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value,
                                 deadzone: 0.15, exponent: 1.6) {
            delegate?.controllerActivity()
            let speed = CGFloat(150 + d.scrollSpeed * 2350) * CGFloat(dt)
            let sign: CGFloat = d.invertScroll ? -1 : 1
            out.scroll(dx: -vx * speed * sign, dy: vy * speed * sign)
        }
    }

    var sticksDeflected: Bool {
        guard let pad = controller?.extendedGamepad else { return false }
        return hypot(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value) > 0.2
            || hypot(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value) > 0.2
    }

    // MARK: Touchpad (DualSense / DualShock)

    private func touchpadPads(_ pad: GCExtendedGamepad) -> (GCControllerDirectionPad, GCControllerDirectionPad)? {
        if let ds = pad as? GCDualSenseGamepad { return (ds.touchpadPrimary, ds.touchpadSecondary) }
        if let ds4 = pad as? GCDualShockGamepad { return (ds4.touchpadPrimary, ds4.touchpadSecondary) }
        return nil
    }

    private func isTwoFingerTouch() -> Bool {
        guard let pad = controller?.extendedGamepad, let (_, second) = touchpadPads(pad) else { return false }
        return second.xAxis.value != 0 || second.yAxis.value != 0
    }

    private func readTouchpad(_ pad: GCExtendedGamepad, now: Date) {
        guard let (primary, _) = touchpadPads(pad) else { return }
        let x = CGFloat(primary.xAxis.value), y = CGFloat(primary.yAxis.value)
        let touching = x != 0 || y != 0
        if touching {
            if let last = touchLast {
                let scale = CGFloat(500 + settings.data.touchpadSpeed * 1500)
                let dx = (x - last.x) * scale, dy = -(y - last.y) * scale
                if abs(dx) + abs(dy) > 0.01 {
                    touchTravel += hypot(x - last.x, y - last.y)
                    out.movePointer(dx: dx, dy: dy)
                    delegate?.controllerActivity()
                }
            } else {
                touchStart = now
                touchTravel = 0
                delegate?.controllerActivity()
            }
            touchLast = CGPoint(x: x, y: y)
        } else if touchLast != nil {
            // Quick light tap = click
            if !touchClicked, now.timeIntervalSince(touchStart) < 0.18, touchTravel < 0.06, down[.touchpad] == nil {
                perform(Action(kind: .leftClick), phase: .tap)
            }
            touchClicked = false
            touchLast = nil
        }
    }
}
