import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Live status shown in Settings and the menu bar
final class StatusModel: ObservableObject {
    @Published var controllerName = "No controller"
    @Published var connected = false
    @Published var battery: Float?
    @Published var charging = false
    @Published var hasAccessibility = false
    @Published var controllerKeysRunning = false
    @Published var controllerMode = false
    @Published var pausedForGame: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate, ControllerDelegate {
    private let settings = AppSettings.shared
    let status = StatusModel()
    private let controllers = ControllerManager()
    private let out = Output.shared
    private let displayScaler = DisplayScaler()
    private let keyboard = ControllerKeyboard()
    private let snap = SnapNavigator()
    private let voice = VoiceTyping()
    private let voiceCaption = VoiceCaption()
    private let hints = HintsBar()
    private let toast = Toast()
    let updater = Updater()
    private var lowBatteryWarned = false

    private var statusItem: NSStatusItem!
    private var ringPanel: NSPanel!
    private var ringView: RingView!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var controllerMode = false
    private var lastControllerActivity = Date.distantPast
    private var lastPointer = CGPoint.zero
    private var lastDisplayChange = Date.distantPast
    private var shrinkWork: DispatchWorkItem?
    private var followTimer: Timer?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        appliedScreenScale = settings.data.screenScale
        appliedHintsMode = settings.data.hintsMode
        replaceControllerCursor()
        allowBackgroundCursorHiding()
        watchMouseEdges()
        keyboard.onStateChange = { [weak self] in
            self?.updateCursorVisibility()
            self?.refreshHints()
        }
        buildRing()
        buildMenuBar()

        controllers.delegate = self
        controllers.start()

        voice.onUpdate = { [weak self] text in self?.voiceCaption.update(text) }
        voice.shouldType = { [weak self] in !(self?.controllers.paused ?? false) }
        voice.onMessage = { [weak self] msg in self?.toast.show(msg, symbol: "mic.slash.fill", tint: .systemOrange, duration: 4) }

        // Follow the app in front: per-app profiles, and stepping aside for games
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.frontmostChanged()
        }
        frontmostChanged()

        // Install updates on their own only while the controller isn't being used and no game is open
        updater.startAutomaticChecks { [weak self] in
            guard let self else { return false }
            return self.settings.data.autoUpdate && !self.controllerMode && !self.controllers.paused
                && !self.keyboard.isVisible && !self.voice.isActive
        }

        if !out.hasPermission {
            _ = CGRequestPostEventAccess()
            // After an update signed with a new key, macOS keeps a stale entry and won't ask again
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.out.hasPermission else { return }
                self.toast.show("Turn on Console Mode in Accessibility (remove it with − and add it again if it's already on)",
                                symbol: "hand.raised.fill", tint: .systemOrange, duration: 8)
                self.openAccessibility()
            }
        }

        // React to settings changes
        settings.$data.dropFirst().debounce(for: .milliseconds(50), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.settingsChanged()
        }.store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.keyboard.pointRatio = self.displayScaler.pointRatio
            self.keyboard.refresh()
            if self.hints.shown { self.refreshHints() }
        }

        let statusTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStatus() }
        RunLoop.main.add(statusTimer, forMode: .common)
        refreshStatus()

        // First launch: show Settings so permissions and ControllerKeys can be sorted out
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        showArrow()
        voice.stop()
        settings.saveNow()
        displayScaler.restore()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private var appliedScreenScale: Double?
    private var appliedHintsMode: HintsMode?

    /// Every setting takes effect right away
    private func settingsChanged() {
        let d = settings.data
        out.crossAnyEdge = d.crossAnyEdge
        // Screen size: switch now if the controller is in use
        if appliedScreenScale != d.screenScale {
            appliedScreenScale = d.screenScale
            if controllerMode, !controllers.paused {
                if displayScaler.restore() { lastDisplayChange = Date() }
                if displayScaler.scaleUp(factor: d.screenScale) { lastDisplayChange = Date() }
                keyboard.pointRatio = displayScaler.pointRatio
                keyboard.refresh()
            }
        }
        if appliedHintsMode != d.hintsMode {
            appliedHintsMode = d.hintsMode
            refreshHints()
        }
        controllers.applyGestureStates()
        frontmostChanged()
        controllers.applyLight()
        ringView.diameter = d.circleSize
        let size = d.circleSize + 16
        ringPanel.setContentSize(NSSize(width: size, height: size))
        ringView.frame = NSRect(x: 0, y: 0, width: size, height: size)
        keyboard.keySize = CGFloat(d.keyboardKeySize)
        keyboard.refresh()
        if !d.enabled { setControllerMode(false) }
        rebuildMenu()
    }

    private func refreshStatus() {
        status.controllerName = controllers.controller == nil ? "No controller" : controllers.name
        status.connected = controllers.controller != nil
        status.battery = controllers.batteryLevel
        status.charging = controllers.charging
        status.hasAccessibility = out.hasPermission
        status.controllerKeysRunning = !controllerKeysApps().isEmpty
        // Low battery warning, once per discharge
        if let b = status.battery {
            if b < 0.15, !status.charging, !lowBatteryWarned {
                lowBatteryWarned = true
                toast.show("Controller battery low — \(Int(b * 100))%", symbol: "battery.25", tint: .systemRed, duration: 4)
                controllers.rumble(0.9)
            } else if b > 0.25 || status.charging {
                lowBatteryWarned = false
            }
        }
        rebuildMenu()
    }

    // MARK: Games and per-app profiles

    private func frontmostChanged() {
        let app = NSWorkspace.shared.frontmostApplication
        // Ignore Console Mode's own windows (Settings)
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            setPaused(nil)   // Console Mode's own Settings window is never a game
            return
        }
        settings.frontmostBundleID = app?.bundleIdentifier
        controllers.applyGestureStates()
        let game = settings.data.pauseInGames && GameDetector.isGame(app, extra: settings.data.extraGames)
        setPaused(game ? (app?.localizedName ?? "Game") : nil)
    }

    /// While a game is in front, Console Mode steps aside: the game reads the controller itself
    private func setPaused(_ gameName: String?) {
        let paused = gameName != nil
        guard paused != controllers.paused else { return }
        controllers.paused = paused
        status.pausedForGame = gameName
        if paused {
            keyboard.hide()
            voice.stop()
            hints.hide()
            setControllerMode(false)
            shrinkWork?.cancel()
            if displayScaler.restore() { lastDisplayChange = Date(); keyboard.pointRatio = 1 }
            toast.show("\(gameName!) — Console Mode paused", symbol: "gamecontroller.fill", tint: .systemGreen)
        }
        rebuildMenu()
    }

    // MARK: ControllerDelegate

    func controllerActivity() {
        lastControllerActivity = Date()
        setControllerMode(true)
    }

    func controllerChanged() { refreshStatus() }

    func controllerConnected(name: String) {
        var text = "\(name) connected"
        if let b = controllers.batteryLevel { text += " — \(Int(b * 100))%" }
        toast.show(text, symbol: "gamecontroller.fill", tint: .systemBlue)
    }

    func navigate(_ dir: SnapNavigator.Direction) -> Bool {
        // Typing in a text box, or moving through a menu: the D-pad acts as arrow keys
        guard out.hasPermission, !snap.focusedIsTextInput(), !snap.menuOpen() else { return false }
        snap.jump(dir) { [weak self] found in
            guard !found, let self else { return }
            let arrow: ActionKind = dir == .up ? .arrowUp : dir == .down ? .arrowDown : dir == .left ? .arrowLeft : .arrowRight
            if let s = arrow.shortcut { self.out.tap(s) }
        }
        return true
    }

    func voiceTyping(_ start: Bool) {
        if start {
            if voice.isActive { voice.stop() } else { voice.start() }
        } else {
            voice.stop()
        }
    }

    func buttonsChanged(quickMenu: Bool) { refreshHints(quickMenu: quickMenu) }

    /// Jump the pointer to the next (or previous) display, left to right, back where it last was there
    func switchDisplay(forward: Bool) {
        let screens = NSScreen.screens.sorted {
            $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY > $1.frame.minY
        }
        guard screens.count > 1, let primary = NSScreen.screens.first else {
            toast.show("Only one display is connected", symbol: "display")
            return
        }
        let here = NSScreen.withPointer
        let cg = Output.pointerLocation()
        if let here { pointerByDisplay[here.displayID] = cg }
        let i = screens.firstIndex { $0 == here } ?? 0
        let target = screens[(i + (forward ? 1 : screens.count - 1)) % screens.count]
        let f = target.frame
        // NSScreen is bottom-left based; pointer positions are top-left based
        let cgFrame = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        var dest = CGPoint(x: cgFrame.midX, y: cgFrame.midY)
        if let saved = pointerByDisplay[target.displayID], cgFrame.contains(saved) { dest = saved }
        out.movePointer(to: dest)
        followPointer(dest)
        let n = screens.firstIndex(of: target).map { $0 + 1 } ?? 1
        toast.show("\(target.localizedName)  ·  \(n) of \(screens.count)", symbol: "display", duration: 1.6, on: target)
        controllers.rumble(0.3)
        keyboard.followPointerScreen()
        refreshHints()
    }

    private var pointerByDisplay: [CGDirectDisplayID: CGPoint] = [:]
    private var edgeMonitor: Any?
    private var lastEdgeJump = Date.distantPast

    /// The Mac's mouse and trackpad can cross to another display anywhere along a side, too
    private func watchMouseEdges() {
        edgeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            guard let self, e.cgEvent?.getIntegerValueField(.eventSourceUserData) != Output.eventTag,
                  Date().timeIntervalSince(self.lastEdgeJump) > 0.25 else { return }
            let loc = Output.pointerLocation()
            guard let dest = self.out.crossTarget(at: loc, dx: e.deltaX, dy: e.deltaY) else { return }
            self.lastEdgeJump = Date()
            CGWarpMouseCursorPosition(dest)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func showMessage(_ text: String) {
        toast.show(text, symbol: "exclamationmark.bubble.fill", tint: .systemOrange, duration: 4)
    }

    func keyboardTouch(_ point: CGPoint?) -> Bool { keyboard.touch(point) }

    // MARK: Button hints

    private func refreshHints(quickMenu: Bool = false) {
        let mode = settings.data.hintsMode
        guard mode != .off, controllerMode, !controllers.paused else { hints.hide(); return }
        let style = settings.effectiveProfile.style
        func g(_ b: PadButton) -> (String, NSColor) {
            if style == .xbox {
                switch b {
                case .cross: return ("A", .systemGreen)
                case .circle: return ("B", .systemRed)
                case .square: return ("X", .systemBlue)
                case .triangle: return ("Y", .systemYellow)
                case .options: return ("☰", .white)
                case .l2: return ("LT", .white)
                case .r2: return ("RT", .white)
                case .r3: return ("RS", .white)
                default: return (b.glyph, .white)
                }
            }
            switch b {
            case .cross: return ("✕", NSColor(calibratedRed: 0.5, green: 0.65, blue: 1, alpha: 1))
            case .circle: return ("○", NSColor(calibratedRed: 1, green: 0.42, blue: 0.45, alpha: 1))
            case .square: return ("□", NSColor(calibratedRed: 1, green: 0.55, blue: 0.85, alpha: 1))
            case .triangle: return ("△", NSColor(calibratedRed: 0.3, green: 0.85, blue: 0.7, alpha: 1))
            default: return (b.glyph, .white)
            }
        }
        var items: [(glyph: String, color: NSColor, title: String)] = []
        func add(_ b: PadButton, _ title: String) { let x = g(b); items.append((x.0, x.1, title)) }
        if keyboard.isVisible {
            add(.cross, "Type"); add(.square, "Delete"); add(.r3, "Space"); add(.l2, "Shift")
            add(.r2, "Return"); add(.circle, "Close")
        } else {
            for b in [PadButton.cross, .circle, .square, .triangle, .options] {
                let bind = settings.binding(for: b, quickMenu: quickMenu)
                guard bind.press.kind != .none else { continue }
                var title = bind.press.kind == .shortcut ? bind.press.title : bind.press.kind.shortTitle
                if bind.hold.kind == .voiceTyping || bind.hold.kind == .siri {
                    title += " (hold: \(bind.hold.kind.shortTitle))"
                }
                add(b, title)
            }
            if !quickMenu { add(.l2, "Quick Menu") }
            if quickMenu {
                for b in [PadButton.l1, .r1, .l3] {
                    let kind = settings.binding(for: b, quickMenu: true).press.kind
                    guard kind != .none, kind != .shortcut else { continue }
                    if kind == .nextDisplay || kind == .previousDisplay, NSScreen.screens.count < 2 { continue }
                    add(b, kind.shortTitle)
                }
            }
        }
        hints.scale = displayScaler.pointRatio
        hints.bottomInset = keyboard.isVisible ? keyboard.topEdge : 0
        hints.anchorScreen = keyboard.isVisible ? keyboard.currentScreen : nil
        hints.show(items, autoHideAfter: mode == .autoHide ? 4 : nil)
    }

    /// The stick or touchpad moved the pointer: aim with the circle again instead of the D-pad highlight
    func pointerMovedByController() { keyboard.clearFocus() }

    var keyboardVisible: Bool { keyboard.isVisible }

    func toggleKeyboard() {
        keyboard.keySize = CGFloat(settings.data.keyboardKeySize)
        keyboard.pointRatio = displayScaler.pointRatio
        keyboard.toggle()
    }

    /// PS5 keyboard controls while the keyboard is open
    func keyboardButton(_ button: PadButton, down: Bool) -> Bool {
        // ✕ types the highlighted key after D-pad navigation; otherwise it clicks under the circle
        if button == .cross {
            guard down else { return true }
            guard keyboard.activateFocused() else { return false }
            controllers.rumble(0.3)
            return true
        }
        let handled: Set<PadButton> = [.square, .triangle, .circle, .l1, .r1, .r2, .l2, .r3, .l3, .options, .create,
                                       .up, .down, .left, .right, .touchpad]
        guard handled.contains(button) else { return false }
        if button == .touchpad && !settings.data.swipeTyping { return false }
        guard down else { return true }
        switch button {
        case .up: keyboard.moveFocus(.up)
        case .down: keyboard.moveFocus(.down)
        case .left: keyboard.moveFocus(.left)
        case .right: keyboard.moveFocus(.right)
        case .square: keyboard.backspace()
        case .r3: keyboard.typeSpace()
        case .triangle, .circle, .options: keyboard.hide()
        case .l1: keyboard.cursorLeft()
        case .r1: if !keyboard.nextSuggestion() { keyboard.cursorRight() }
        case .l3: voiceTyping(true)
        case .touchpad: break   // the touchpad types (tap or swipe) while the keyboard is open
        case .r2: keyboard.returnKey()
        case .l2: keyboard.toggleShift()
        case .create: keyboard.toggleSymbols()
        default: break
        }
        controllers.rumble(0.3)
        return true
    }

    // MARK: Controller mode (circle + bigger screen)

    private func setControllerMode(_ on: Bool) {
        let on = on && settings.data.enabled
        guard on != controllerMode else { return }
        controllerMode = on
        status.controllerMode = on
        if on {
            if settings.data.hintsMode == .always { DispatchQueue.main.async { [weak self] in self?.refreshHints() } }
            shrinkWork?.cancel()
            if displayScaler.scaleUp(factor: settings.data.screenScale) {
                lastDisplayChange = Date()
                keyboard.pointRatio = displayScaler.pointRatio
            }
            lastPointer = Output.pointerLocation()
            followPointer()
            updateCursorVisibility()
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            followTimer = t
        } else {
            followTimer?.invalidate()
            followTimer = nil
            ringPanel.orderOut(nil)
            hints.hide()
            keyboard.clearFocus()   // using the mouse: bring the arrow back
            // Back to normal size once you've stuck with the mouse for a moment
            shrinkWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.controllerMode else { return }
                if self.displayScaler.restore() {
                    self.lastDisplayChange = Date()
                    self.keyboard.pointRatio = 1
                }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func tick() {
        let now = Date()
        let p = Output.pointerLocation()
        defer { lastPointer = p; followPointer(p); keepArrowHidden() }
        // The pointer jumps when the screen size changes; don't mistake that for the mouse
        guard now.timeIntervalSince(lastDisplayChange) > 2 else { return }
        if p != lastPointer,
           now.timeIntervalSince(out.lastPointerPost) > 0.15,
           now.timeIntervalSince(lastControllerActivity) > 0.35,
           !controllers.sticksDeflected {
            setControllerMode(false)   // the mouse or trackpad moved it
        }
    }

    // MARK: Hiding the cursor while typing

    private var arrowHidden = false

    /// While you type with the D-pad, neither the circle nor the arrow is shown
    private func updateCursorVisibility() {
        // Only with the controller: opened from the menu with a mouse, keep the arrow
        let typing = keyboard.isVisible && keyboard.focusActive && controllerMode
        if typing {
            ringPanel.orderOut(nil)
            if !arrowHidden {
                CGDisplayHideCursor(CGMainDisplayID())
                hideCount = 1
                arrowHidden = true
            }
        } else {
            showArrow()
            if controllerMode { followPointer(); ringPanel.orderFrontRegardless() }
        }
    }

    private func showArrow() {
        guard arrowHidden else { return }
        for _ in 0..<max(1, hideCount) { CGDisplayShowCursor(CGMainDisplayID()) }
        hideCount = 0
        arrowHidden = false
    }

    private var hideCount = 0

    /// Swift hides CGCursorIsVisible, but CoreGraphics still has it
    private static let cursorIsVisible: (@convention(c) () -> Int32)? = {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(f, to: (@convention(c) () -> Int32).self)
    }()

    /// Some apps force the arrow back on (cursor changes, windows opening); hide it again
    private func keepArrowHidden() {
        guard arrowHidden, hideCount < 8, let isVisible = Self.cursorIsVisible, isVisible() != 0 else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    /// Lets this background app hide the arrow (macOS normally only allows the frontmost app)
    private func allowBackgroundCursorHiding() {
        typealias DefaultConnFn = @convention(c) () -> Int32
        typealias SetPropFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let a = dlsym(handle, "_CGSDefaultConnection"),
              let b = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let conn = unsafeBitCast(a, to: DefaultConnFn.self)()
        _ = unsafeBitCast(b, to: SetPropFn.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    // MARK: Circle

    private func buildRing() {
        let size = settings.data.circleSize + 16
        ringPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ringPanel.isOpaque = false
        ringPanel.backgroundColor = .clear
        ringPanel.hasShadow = false
        ringPanel.hidesOnDeactivate = false
        ringPanel.ignoresMouseEvents = true
        ringPanel.level = .screenSaver
        ringPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ringView = RingView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        ringView.diameter = settings.data.circleSize
        ringPanel.contentView = ringView
    }

    private func followPointer(_ cg: CGPoint? = nil) {
        let loc = cg ?? Output.pointerLocation()
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        let s = ringPanel.frame.size
        ringPanel.setFrameOrigin(NSPoint(x: loc.x - s.width / 2, y: maxY - loc.y - s.height / 2))
    }

    // MARK: Taking over from Controller Cursor

    /// Console Mode replaces the older Controller Cursor app: bring over its settings once,
    /// quit it (it puts the normal cursor and screen size back as it quits), and move it to the Trash.
    private func replaceControllerCursor() {
        let oldID = "com.nate.controllercursor"
        if !UserDefaults.standard.bool(forKey: "importedControllerCursor"),
           let old = UserDefaults(suiteName: oldID) {
            if let ring = old.object(forKey: "ringSize") as? Double { settings.data.circleSize = ring }
            if let scale = old.object(forKey: "screenScale") as? Double { settings.data.screenScale = scale }
            if let keys = old.object(forKey: "keyboardKeySize") as? Double { settings.data.keyboardKeySize = keys }
            UserDefaults.standard.set(true, forKey: "importedControllerCursor")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: oldID)
        running.forEach { $0.terminate() }
        // Give it a moment to quit, then move it to the Trash (recoverable)
        DispatchQueue.main.asyncAfter(deadline: .now() + (running.isEmpty ? 0 : 1.5)) {
            NSRunningApplication.runningApplications(withBundleIdentifier: oldID).forEach { $0.forceTerminate() }
            var urls: [URL] = []
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: oldID) { urls.append(u) }
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
                let u = URL(fileURLWithPath: dir).appendingPathComponent("Controller Cursor.app")
                if FileManager.default.fileExists(atPath: u.path), !urls.contains(u) { urls.append(u) }
            }
            let ownPath = Bundle.main.bundleURL.standardizedFileURL
            let toTrash = urls.filter { $0.standardizedFileURL != ownPath }
            if !toTrash.isEmpty { NSWorkspace.shared.recycle(toTrash) { _, _ in } }
        }
    }

    // MARK: ControllerKeys

    private func controllerKeysApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier ?? "").contains("XboxControllerMapper") || ($0.localizedName ?? "") == "ControllerKeys"
        }
    }

    @objc func quitControllerKeys() {
        controllerKeysApps().forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshStatus() }
    }

    // MARK: Menu bar

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Console Mode")
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        var line = status.controllerName
        if let b = status.battery { line += " — \(Int(b * 100))%" + (status.charging ? " ⚡︎" : "") }
        let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        if let game = status.pausedForGame {
            let paused = NSMenuItem(title: "Paused while \(game) is open", action: nil, keyEquivalent: "")
            paused.isEnabled = false
            menu.addItem(paused)
        }
        if !status.hasAccessibility {
            menu.addItem(item("⚠︎ Needs Accessibility Permission…", #selector(openAccessibility)))
        }
        if status.controllerKeysRunning {
            menu.addItem(item("⚠︎ Quit ControllerKeys (it's still running)", #selector(quitControllerKeys)))
        }
        menu.addItem(.separator())
        let enabled = item("Use Controller", #selector(toggleEnabled))
        enabled.state = settings.data.enabled ? .on : .off
        menu.addItem(enabled)
        let profMenu = NSMenu()
        for prof in settings.data.profiles {
            let pi = NSMenuItem(title: prof.name, action: #selector(pickProfile(_:)), keyEquivalent: "")
            pi.representedObject = prof.id
            pi.target = self
            pi.state = prof.id == settings.data.activeProfileID ? .on : .off
            profMenu.addItem(pi)
        }
        let profItem = NSMenuItem(title: "Profile: \(settings.activeProfile.name)", action: nil, keyEquivalent: "")
        profItem.submenu = profMenu
        menu.addItem(profItem)
        menu.addItem(item("Show Keyboard", #selector(menuKeyboard)))
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…", #selector(checkUpdates)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Console Mode", #selector(quit), key: "q"))
        statusItem.menu = menu
        statusItem.button?.appearsDisabled = !settings.data.enabled
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() { settings.data.enabled.toggle() }
    @objc private func pickProfile(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { settings.data.activeProfileID = id }
    }
    @objc private func menuKeyboard() { toggleKeyboard() }
    @objc private func checkUpdates() {
        updater.check(install: true)
        openSettings()
    }

    @objc func openAccessibility() {
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(status: status, live: controllers.live, updater: updater, actions: SettingsActions(
                openAccessibility: { [weak self] in self?.openAccessibility() },
                quitControllerKeys: { [weak self] in self?.quitControllerKeys() },
                testRumble: { [weak self] in self?.controllers.rumble(0.8) }
            ))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Console Mode"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.setFrameAutosaveName("ConsoleModeSettings")
            if !w.setFrameUsingName("ConsoleModeSettings") { w.center() }
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        showArrow()
        displayScaler.restore()
        NSApp.terminate(nil)
    }
}
