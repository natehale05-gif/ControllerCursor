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
}

final class AppDelegate: NSObject, NSApplicationDelegate, ControllerDelegate {
    private let settings = AppSettings.shared
    let status = StatusModel()
    private let controllers = ControllerManager()
    private let out = Output.shared
    private let displayScaler = DisplayScaler()
    private let keyboard = ControllerKeyboard()

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
        buildRing()
        buildMenuBar()

        controllers.delegate = self
        controllers.start()

        if !out.hasPermission { _ = CGRequestPostEventAccess() }

        // React to settings changes
        settings.$data.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.settingsChanged()
        }.store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.keyboard.pointRatio = self.displayScaler.pointRatio
            self.keyboard.refresh()
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
        displayScaler.restore()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func settingsChanged() {
        let d = settings.data
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
        rebuildMenu()
    }

    // MARK: ControllerDelegate

    func controllerActivity() {
        lastControllerActivity = Date()
        setControllerMode(true)
    }

    func controllerChanged() { refreshStatus() }

    var keyboardVisible: Bool { keyboard.isVisible }

    func toggleKeyboard() {
        keyboard.keySize = CGFloat(settings.data.keyboardKeySize)
        keyboard.pointRatio = displayScaler.pointRatio
        keyboard.toggle()
    }

    /// PS5 keyboard controls while the keyboard is open
    func keyboardButton(_ button: PadButton, down: Bool) -> Bool {
        let handled: Set<PadButton> = [.square, .triangle, .circle, .l1, .r1, .r2, .l2, .options, .create]
        guard handled.contains(button) else { return false }
        guard down else { return true }
        switch button {
        case .square: keyboard.backspace()
        case .triangle: keyboard.typeSpace()
        case .circle, .options: keyboard.hide()
        case .l1: keyboard.cursorLeft()
        case .r1: keyboard.cursorRight()
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
        if on {
            shrinkWork?.cancel()
            if displayScaler.scaleUp(factor: settings.data.screenScale) {
                lastDisplayChange = Date()
                keyboard.pointRatio = displayScaler.pointRatio
            }
            lastPointer = Output.pointerLocation()
            followPointer()
            ringPanel.orderFrontRegardless()
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            followTimer = t
        } else {
            followTimer?.invalidate()
            followTimer = nil
            ringPanel.orderOut(nil)
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
        defer { lastPointer = p; followPointer(p) }
        // The pointer jumps when the screen size changes; don't mistake that for the mouse
        guard now.timeIntervalSince(lastDisplayChange) > 2 else { return }
        if p != lastPointer,
           now.timeIntervalSince(out.lastPointerPost) > 0.15,
           now.timeIntervalSince(lastControllerActivity) > 0.35,
           !controllers.sticksDeflected {
            setControllerMode(false)   // the mouse or trackpad moved it
        }
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
        menu.addItem(item("Show Keyboard", #selector(menuKeyboard)))
        menu.addItem(.separator())
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
    @objc private func menuKeyboard() { toggleKeyboard() }

    @objc func openAccessibility() {
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(status: status, actions: SettingsActions(
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
        displayScaler.restore()
        NSApp.terminate(nil)
    }
}
