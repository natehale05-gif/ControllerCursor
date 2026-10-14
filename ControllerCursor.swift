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
    private var lastControllerInput = Date.distantPast
    private var stickHeld = false
    private var pidIsControllerKeys: [pid_t: Bool] = [:]
    private var requestedPermission = false
    private var needsPermission = false

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var hideArrow: Bool {
        get { defaults.object(forKey: "hideArrow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hideArrow") }
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
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
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

    private func followCursor() {
        let p = NSEvent.mouseLocation
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
            followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                self?.followCursor()
            }
            RunLoop.main.add(followTimer!, forMode: .common)
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

    private var controllerRecentlyActive: Bool {
        let age = Date().timeIntervalSince(lastControllerInput)
        return (stickHeld && age < 2.0) || age < 0.3
    }

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let synthetic = pid != 0 && pid != getpid()
        let fromController: Bool
        if synthetic {
            // Mouse utilities (Logi Options+, Mac Mouse Fix…) re-post real mouse moves, so these count as mouse
            fromController = isControllerKeys(pid) || controllerRecentlyActive
        } else {
            // Hardware event, unless the controller is mid-use and macOS didn't tag the source
            fromController = controllerRecentlyActive
        }

        setControllerMode(fromController)

        if controllerMode {
            switch type {
            case .leftMouseDown, .rightMouseDown: ringView.pressed = true
            case .leftMouseUp, .rightMouseUp: ringView.pressed = false
            default: break
            }
            followCursor()
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
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil,
                                               queue: .main) { [weak self] _ in self?.stickHeld = false }
        GCController.controllers().forEach { watch($0) }
    }

    private func watch(_ controller: GCController) {
        controller.physicalInputProfile.valueDidChangeHandler = { [weak self, weak controller] _, _ in
            guard let self, let controller else { return }
            self.lastControllerInput = Date()
            if let pad = controller.extendedGamepad {
                let l = hypot(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
                let r = hypot(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
                self.stickHeld = l > 0.25 || r > 0.25
            }
            // Pressing any button also switches to the circle, like waking a console
            self.setControllerMode(true)
        }
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

        let hide = NSMenuItem(title: "Hide Arrow While Using Controller", action: #selector(toggleHideArrow), keyEquivalent: "")
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
