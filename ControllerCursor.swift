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
    private var cursorHiddenByUs = false
    private var lastControllerActivity = Date.distantPast
    private var pidIsControllerKeys: [pid_t: Bool] = [:]
    private var requestedPermission = false
    private var needsPermission = false

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var hideArrow: Bool {
        // Off by default: ControllerKeys' "Relative Mouse Aiming = Auto" treats a hidden arrow
        // as an FPS game locking the mouse and freezes the pointer.
        get { defaults.object(forKey: "hideArrowV2") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "hideArrowV2") }
    }
    private var ringSize: Double {
        get { defaults.object(forKey: "ringSize") as? Double ?? 44 }
        set { defaults.set(newValue, forKey: "ringSize") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Allow this background app to hide the system arrow while the circle is showing
        allowBackgroundCursorHiding()

        buildPanel()
        buildMenu()
        startControllerMonitoring()
        startEventTap()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.pidIsControllerKeys.removeAll() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreArrow()
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
            panel.orderFrontRegardless()
            if hideArrow { hideSystemArrow() }
            // Always attach to the main run loop, whichever thread asked
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                self?.followCursor()
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        } else {
            followTimer?.invalidate()
            followTimer = nil
            ringView.pressed = false
            panel.orderOut(nil)
            restoreArrow()
        }
    }

    private func hideSystemArrow() {
        guard !cursorHiddenByUs else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHiddenByUs = true
    }

    private func restoreArrow() {
        guard cursorHiddenByUs else { return }
        CGDisplayShowCursor(CGMainDisplayID())
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

        let hide = NSMenuItem(title: "Hide Arrow (needs ControllerKeys Relative Mouse Aiming: Off)", action: #selector(toggleHideArrow), keyEquivalent: "")
        hide.state = hideArrow ? .on : .off
        menu.addItem(hide)

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
