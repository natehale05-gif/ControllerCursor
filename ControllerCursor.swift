// Controller Cursor
// Shows a circle cursor while a game controller (via ControllerKeys) is driving the pointer,
// and switches back to the normal macOS arrow the moment a real mouse or trackpad moves.

import AppKit
import GameController
import ServiceManagement

// MARK: - Private CoreGraphics calls
// Lets a background app hide/show the system cursor (normally only the frontmost app can).
private func allowBackgroundCursorHiding() {
    typealias DefaultConnFn = @convention(c) () -> Int32
    typealias SetPropFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    guard let a = dlsym(handle, "_CGSDefaultConnection"),
          let b = dlsym(handle, "CGSSetConnectionProperty") else { return }
    let conn = unsafeBitCast(a, to: DefaultConnFn.self)()
    _ = unsafeBitCast(b, to: SetPropFn.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

// MARK: - Ring drawing

final class RingView: NSView {
    var diameter: CGFloat = 44 { didSet { needsDisplay = true } }
    var pressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let d = pressed ? diameter * 0.8 : diameter
        let rect = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let ring = NSBezierPath(ovalIn: rect)

        // Soft fill so it reads like a console cursor
        NSColor.white.withAlphaComponent(pressed ? 0.40 : 0.18).setFill()
        ring.fill()

        // Dark outer edge keeps it visible on white pages
        NSColor.black.withAlphaComponent(0.45).setStroke()
        ring.lineWidth = 6
        ring.stroke()

        // Bright ring
        NSColor.white.setStroke()
        ring.lineWidth = 3
        ring.stroke()

        // Center dot marks the exact click point
        let dot: CGFloat = 5
        let dotPath = NSBezierPath(ovalIn: NSRect(x: bounds.midX - dot / 2, y: bounds.midY - dot / 2,
                                                  width: dot, height: dot))
        NSColor.white.setFill()
        dotPath.fill()
        NSColor.black.withAlphaComponent(0.5).setStroke()
        dotPath.lineWidth = 1
        dotPath.stroke()
    }
}

// MARK: - System cursor swap (same private CoreGraphics calls Mousecape uses)

enum CircleCursor {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias RegisterFn = @convention(c) (Int32, UnsafeMutablePointer<CChar>, CBool, CBool,
                                                   CGSize, CGPoint, UInt, CGFloat, CFArray,
                                                   UnsafeMutablePointer<Int32>) -> Int32
    private typealias UnregisterAllFn = @convention(c) (Int32) -> Int32
    private typealias SetFn = @convention(c) (Int32, Int32) -> Int32

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(p, to: type)
    }
    private static let mainConn = sym("CGSMainConnectionID", MainConnFn.self)
    private static let register = sym("CGSRegisterCursorWithImages", RegisterFn.self)
    private static let unregisterAll = sym("CoreCursorUnregisterAll", UnregisterAllFn.self)
    private static let coreSet = sym("CoreCursorSet", SetFn.self)

    static var isSupported: Bool { mainConn != nil && register != nil && unregisterAll != nil }

    /// Every cursor apps can switch to becomes the circle (arrow, text, link hand, buttons,
    /// resize, drag…), except the busy/wait spinners and the blank cursor.
    private static let coreGraphicsNames = [
        "com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowCtx",
        "com.apple.coregraphics.IBeam", "com.apple.coregraphics.IBeamXOR",
        "com.apple.coregraphics.Alias", "com.apple.coregraphics.Copy", "com.apple.coregraphics.Move",
    ]
    private static let skippedNumbered: Set<Int> = [4] // Busy
    /// The numbered system cursors that actually exist (2–43, per Mousecape)
    private static let numberedRange = 2...43

    private static func ringImage(points: CGFloat, diameter: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int(points * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let view = RingView(frame: NSRect(x: 0, y: 0, width: points, height: points))
        view.diameter = diameter
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Replaces the system pointer cursors with the circle. Returns false if macOS refused.
    @discardableResult
    static func apply(diameter: CGFloat) -> Bool {
        guard isSupported, let mainConn, let register else { return false }
        let points = diameter + 12
        let images = [1.0, 2.0, 3.0].compactMap { ringImage(points: points, diameter: diameter, scale: $0) }
        guard !images.isEmpty else { return false }
        let cid = mainConn()
        var ok = false
        let numbered = numberedRange.filter { !skippedNumbered.contains($0) }
        let names = coreGraphicsNames + numbered.map { "com.apple.cursor.\($0)" }
        for name in names {
            var seed: Int32 = 0
            let err = name.withCString { cName in
                register(cid, UnsafeMutablePointer(mutating: cName), true, true,
                         CGSize(width: points, height: points), CGPoint(x: points / 2, y: points / 2),
                         1, 0, images as CFArray, &seed)
            }
            if err == 0 { ok = true }
        }
        if ok { UserDefaults.standard.set(true, forKey: "circleCursorApplied") }
        return ok
    }

    /// Puts every system cursor back to normal.
    static func restore() {
        guard let mainConn, let unregisterAll else { return }
        let cid = mainConn()
        if unregisterAll(cid) == 0, let coreSet {
            for i in 0..<45 { _ = coreSet(cid, Int32(i)) }
            _ = coreSet(cid, 0)
        }
        UserDefaults.standard.set(false, forKey: "circleCursorApplied")
    }

    /// If the app quit unexpectedly while the circle was applied, put the arrow back.
    static func restoreIfLeftApplied() {
        if UserDefaults.standard.bool(forKey: "circleCursorApplied") { restore() }
    }
}

// MARK: - Event tap callback (C function)

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { app.handle(type: type, event: event) }
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var ringView: RingView!
    private var followTimer: Timer?
    private var retryTimer: Timer?
    private var eventTap: CFMachPort?

    private var controllerMode = false
    private var cursorSwapped = false
    private var signalSources: [DispatchSourceSignal] = []
    private var cursorHiddenByUs = false
    private var lastControllerActivity = Date.distantPast
    private var lastPointerPoint = NSPoint.zero
    private var pointerStillSince = Date()
    private var hideCount = 0
    private var arrowFallbackThisSession = false
    private let warpQueue = DispatchQueue(label: "controllercursor.warp")
    private var pendingWarp: CGPoint?
    private let warpLock = NSLock()
    private var lastRehide = Date.distantPast
    private var pidIsControllerKeys: [pid_t: Bool] = [:]
    private var requestedPermission = false
    private var needsPermission = false

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    /// The arrow is never hidden any more: hiding it from a background app confuses ControllerKeys
    /// and macOS keeps bringing it back. The circle replaces the arrow image instead.
    private var hideArrow: Bool {
        get { false }
        set { }
    }
    /// true = the system cursor itself becomes the circle; false = circle drawn around the arrow
    private var swapCursor: Bool {
        get { defaults.object(forKey: "swapCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "swapCursor") }
    }
    private var ringSize: Double {
        get { defaults.object(forKey: "ringSize") as? Double ?? 44 }
        set { defaults.set(newValue, forKey: "ringSize") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Allow this background app to hide the system arrow while the circle is showing
        allowBackgroundCursorHiding()
        CircleCursor.restoreIfLeftApplied()
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                CircleCursor.restoreIfLeftApplied()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }

        buildPanel()
        buildMenu()
        startControllerMonitoring()
        startEventTap()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.pidIsControllerKeys.removeAll() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            for delay in [0.0, 0.1, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.reassertHide() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreArrow()
        CircleCursor.restoreIfLeftApplied()
    }

    // MARK: Overlay panel

    private func buildPanel() {
        let size = ringSize + 16
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ringView = RingView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        ringView.diameter = ringSize
        panel.contentView = ringView
    }

    private func resizeRing() {
        let size = ringSize + 16
        panel.setContentSize(NSSize(width: size, height: size))
        ringView.frame = NSRect(x: 0, y: 0, width: size, height: size)
        ringView.diameter = ringSize
        followCursor()
        if cursorSwapped { CircleCursor.apply(diameter: ringSize) }
    }

    /// Live pointer position straight from the window server, in AppKit (bottom-left) coordinates.
    /// NSEvent.mouseLocation can go stale when another app (ControllerKeys) moves the pointer.
    private func currentCursorPoint() -> NSPoint {
        guard let loc = CGEvent(source: nil)?.location,
              let primary = NSScreen.screens.first else { return NSEvent.mouseLocation }
        return NSPoint(x: loc.x, y: primary.frame.maxY - loc.y)
    }

    private func followCursor(to point: NSPoint? = nil) {
        let p = point ?? currentCursorPoint()
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: p.x - s.width / 2, y: p.y - s.height / 2))
    }

    // MARK: Mode switching

    private func setControllerMode(_ on: Bool) {
        let on = on && enabled
        guard on != controllerMode else { return }
        controllerMode = on
        if on {
            followCursor()
            if swapCursor && CircleCursor.apply(diameter: ringSize) {
                cursorSwapped = true
            } else {
                panel.orderFrontRegardless()
            }
            if hideArrow && !arrowFallbackThisSession { hideSystemArrow() }
            // Always attach to the main run loop, whichever thread asked
            pointerStillSince = Date()
            lastPointerPoint = currentCursorPoint()
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        } else {
            followTimer?.invalidate()
            followTimer = nil
            ringView.pressed = false
            arrowFallbackThisSession = false
            panel.orderOut(nil)
            if cursorSwapped {
                CircleCursor.restore()
                cursorSwapped = false
            }
            restoreArrow()
        }
    }

    /// If ControllerKeys froze the pointer because the arrow is hidden (its "Relative Mouse
    /// Aiming: Auto" game mode), bring the arrow back and explain the setting once.
    private func tick() {
        guard controllerMode else { return }
        let p = currentCursorPoint()
        let moved = p != lastPointerPoint
        lastPointerPoint = p

        if moved {
            pointerStillSince = Date()
            // The pointer moved but the controller has been idle: a mouse or trackpad moved it.
            if !sticksDeflected && Date().timeIntervalSince(lastControllerActivity) > 0.35 {
                setControllerMode(false)
                return
            }
        }
        followCursor(to: p)


        if !moved { checkForFrozenPointer() }
    }

    /// Last-resort safety net: if the pointer still won't move while hidden, show the arrow
    /// for the rest of this controller session instead of leaving you stuck.
    private func checkForFrozenPointer() {
        guard cursorHiddenByUs, sticksDeflected,
              Date().timeIntervalSince(pointerStillSince) > 0.6 else { return }
        arrowFallbackThisSession = true
        restoreArrow()
    }

    /// Moves the real pointer off the main thread (each warp is a slow round trip to the
    /// window server), keeping only the newest target if moves arrive faster than warps finish.
    private func syncPointer(to point: CGPoint) {
        warpLock.lock()
        let alreadyQueued = pendingWarp != nil
        pendingWarp = point
        warpLock.unlock()
        guard !alreadyQueued else { return }
        warpQueue.async { [weak self] in
            guard let self else { return }
            self.warpLock.lock()
            let target = self.pendingWarp
            self.pendingWarp = nil
            self.warpLock.unlock()
            guard let target else { return }
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1) // cancel the warp's brief input freeze
        }
    }

    /// macOS only hides the arrow on a 0 → 1 change of our hide count, so after something
    /// re-shows it (a click activating another app), fully unhide and hide again.
    private func reassertHide() {
        guard cursorHiddenByUs, hideArrow, !arrowFallbackThisSession else { return }
        for _ in 0..<max(hideCount, 1) { CGDisplayShowCursor(CGMainDisplayID()) }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount = 1
        lastRehide = Date()
    }

    private func hideSystemArrow() {
        guard !cursorHiddenByUs else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount = 1
        cursorHiddenByUs = true
    }

    private func restoreArrow() {
        guard cursorHiddenByUs else { return }
        for _ in 0..<max(hideCount, 1) { CGDisplayShowCursor(CGMainDisplayID()) }
        hideCount = 0
        cursorHiddenByUs = false
    }

    // MARK: Detecting who moved the pointer

    private func isControllerKeys(_ pid: pid_t) -> Bool {
        if let cached = pidIsControllerKeys[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let id = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? ""
        let result = id.contains("XboxControllerMapper") || name.contains("ControllerKeys")
        pidIsControllerKeys[pid] = result
        return result
    }

    /// Live check: is either stick pushed past its deadzone right now? (ignores small drift)
    private var sticksDeflected: Bool {
        GCController.controllers().contains { c in
            guard let p = c.extendedGamepad else { return false }
            return hypot(p.leftThumbstick.xAxis.value, p.leftThumbstick.yAxis.value) > 0.25
                || hypot(p.rightThumbstick.xAxis.value, p.rightThumbstick.yAxis.value) > 0.25
        }
    }

    /// True while the controller is what's driving the pointer
    private var controllerDriving: Bool {
        sticksDeflected || Date().timeIntervalSince(lastControllerActivity) < 0.35
    }

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let fromControllerKeys = pid != 0 && pid != getpid() && isControllerKeys(pid)

        // ControllerKeys only counts if the controller was really used in the last second;
        // anything else the controller isn't producing came from a real mouse/trackpad.
        let recentlyUsed = Date().timeIntervalSince(lastControllerActivity) < 1.0
        setControllerMode(controllerDriving || (fromControllerKeys && recentlyUsed))

        if controllerMode {
            switch type {
            case .leftMouseDown, .rightMouseDown: ringView.pressed = true
            case .leftMouseUp, .rightMouseUp: ringView.pressed = false
            default: break
            }
            if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(type) {
                // The clicked app becomes active and macOS shows the arrow; hide it again right after
                for delay in [0.05, 0.2, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reassertHide() }
                }
            }
            // While the arrow is hidden, macOS stops moving the real pointer for ControllerKeys'
            // events, so the pointer and ControllerKeys drift apart. Put the pointer where
            // ControllerKeys says it is, and draw the circle there.
            // (Applied to every move: for real mouse events the location already matches, so it's a no-op.)
            if cursorHiddenByUs, !arrowFallbackThisSession,
               [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
                let loc = event.location
                syncPointer(to: loc)
                let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
                let p = NSPoint(x: loc.x, y: primaryMaxY - loc.y)
                lastPointerPoint = p
                pointerStillSince = Date()
                followCursor(to: p)
            }
        }
    }

    private func startEventTap() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                    .rightMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: tapCallback, userInfo: refcon) else {
            // Needs Input Monitoring permission. Ask once, then keep retrying quietly.
            if !requestedPermission && !CGPreflightListenEventAccess() {
                requestedPermission = true
                _ = CGRequestListenEventAccess()
            }
            if retryTimer == nil {
                retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.startEventTap()
                }
            }
            updateStatusIcon(needsPermission: true)
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        updateStatusIcon(needsPermission: false)
    }

    // MARK: Controller input (any button, stick, or touchpad)

    private func startControllerMonitoring() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil,
                                               queue: .main) { [weak self] note in
            if let c = note.object as? GCController { self?.watch(c) }
        }
        GCController.controllers().forEach { watch($0) }
    }

    private func watch(_ controller: GCController) {
        controller.handlerQueue = .main
        controller.physicalInputProfile.valueDidChangeHandler = { [weak self, weak controller] _, element in
            // GameController can call this off the main thread; all UI work must happen on main
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                self.controllerElementChanged(element, on: controller)
            }
        }
    }

    /// Only deliberate input counts: a button press, a stick pushed past its deadzone,
    /// or a finger on the touchpad. Sensor noise and drift are ignored.
    private func controllerElementChanged(_ element: GCControllerElement, on controller: GCController) {
        var deliberate = false
        if let button = element as? GCControllerButtonInput {
            deliberate = button.isPressed
        } else if let pad = element as? GCControllerDirectionPad {
            if let ds = controller.extendedGamepad as? GCDualSenseGamepad,
               pad === ds.touchpadPrimary || pad === ds.touchpadSecondary {
                deliberate = true
            } else {
                deliberate = hypot(pad.xAxis.value, pad.yAxis.value) > 0.25
            }
        } else if let axis = element as? GCControllerAxisInput {
            deliberate = abs(axis.value) > 0.25
        }
        guard deliberate else { return }
        lastControllerActivity = Date()
        setControllerMode(true)
    }

    // MARK: Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(needsPermission: false)
        rebuildMenu()
    }

    private func updateStatusIcon(needsPermission: Bool) {
        if self.needsPermission != needsPermission {
            self.needsPermission = needsPermission
            if statusItem != nil { rebuildMenu() }
        }
        let name = needsPermission ? "exclamationmark.triangle" : "gamecontroller"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Controller Cursor")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if needsPermission {
            menu.addItem(NSMenuItem(title: "Needs Input Monitoring permission", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Open Privacy Settings…", action: #selector(openPrivacy), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Relaunch After Allowing", action: #selector(relaunch), keyEquivalent: ""))
            menu.addItem(.separator())
        }

        let on = NSMenuItem(title: "Circle Cursor for Controller", action: #selector(toggleEnabled), keyEquivalent: "")
        on.state = enabled ? .on : .off
        menu.addItem(on)

        let styleMenu = NSMenu()
        let swap = NSMenuItem(title: "Circle Replaces Arrow", action: #selector(pickSwap), keyEquivalent: "")
        swap.state = swapCursor ? .on : .off
        swap.isEnabled = CircleCursor.isSupported
        let around = NSMenuItem(title: "Circle Around Arrow", action: #selector(pickAround), keyEquivalent: "")
        around.state = swapCursor ? .off : .on
        [swap, around].forEach { $0.target = self; styleMenu.addItem($0) }
        let styleItem = NSMenuItem(title: "Cursor Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let sizeMenu = NSMenu()
        for (label, value) in [("Small", 32.0), ("Medium", 44.0), ("Large", 56.0), ("Extra Large", 72.0)] {
            let item = NSMenuItem(title: label, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.representedObject = value
            item.state = ringSize == value ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Circle Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Controller Cursor", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        sizeMenu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if !enabled { setControllerMode(false) }
        rebuildMenu()
    }

    @objc private func pickSwap() { switchStyle(swap: true) }
    @objc private func pickAround() { switchStyle(swap: false) }

    private func switchStyle(swap: Bool) {
        let wasOn = controllerMode
        if wasOn { setControllerMode(false) }
        swapCursor = swap
        if wasOn { setControllerMode(true) }
        rebuildMenu()
    }

    @objc private func toggleHideArrow() {
        hideArrow.toggle()
        if controllerMode { hideArrow ? hideSystemArrow() : restoreArrow() }
        rebuildMenu()
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { ringSize = v; resizeRing() }
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "Add Controller Cursor in System Settings → General → Login Items instead."
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func relaunch() {
        restoreArrow()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        restoreArrow()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
