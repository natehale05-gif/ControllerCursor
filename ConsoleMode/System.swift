import AppKit
import ApplicationServices
import CoreWLAN
import IOKit.ps
import IOKit.pwr_mgt

/// Volume, Wi-Fi, appearance, battery, sleep and Shortcuts — the things Control Center reaches
enum SystemControls {
    // MARK: Volume

    private static func script(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    static var volume: Int {
        Int(script("output volume of (get volume settings)")?.int32Value ?? 50)
    }

    static func setVolume(_ v: Int) {
        _ = script("set volume output volume \(max(0, min(100, v)))")
        if isMuted { _ = script("set volume output muted false") }
    }

    static var isMuted: Bool { script("output muted of (get volume settings)")?.booleanValue ?? false }
    static func toggleMute() { _ = script("set volume output muted \(!isMuted)") }

    // MARK: Wi-Fi

    static var wifiOn: Bool? { CWWiFiClient.shared().interface()?.powerOn() }

    static func toggleWiFi() {
        guard let iface = CWWiFiClient.shared().interface() else { return }
        try? iface.setPower(!iface.powerOn())
    }

    // MARK: Appearance

    static var darkMode: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    /// Uses System Events (macOS asks once for permission)
    static func toggleDarkMode() {
        _ = script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
    }

    // MARK: Battery

    /// The Mac's battery: (percent, charging), or nil on a desktop Mac
    static var macBattery: (Int, Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cap * 100 / max, charging)
        }
        return nil
    }

    // MARK: Power

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }

    static func sleep() { run("/usr/bin/pmset", ["sleepnow"]) }
    static func displaySleep() { run("/usr/bin/pmset", ["displaysleepnow"]) }
    static func lock() {
        // ⌃⌘Q — the same as Lock Screen in the Apple menu
        Output.shared.tap(KeyShortcut(keyCode: 12, command: true, control: true))
    }

    private static var lastActivity = Date.distantPast
    private static var activityID: IOPMAssertionID = 0

    /// Controllers don't count as "using the Mac" to macOS. Tell it they do, so the screen doesn't dim
    /// or sleep mid-video, and so a dimmed or sleeping display wakes when you pick the controller up.
    static func declareUserActivity() {
        guard Date().timeIntervalSince(lastActivity) > 5 else { return }
        lastActivity = Date()
        IOPMAssertionDeclareUserActivity("Console Mode controller" as CFString, kIOPMUserActiveLocal, &activityID)
    }

    // MARK: Shortcuts app

    /// Names of the shortcuts in Apple's Shortcuts app
    static func shortcutNames(_ done: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? p.run()) != nil {
                let raw = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                names = String(decoding: raw, as: UTF8.self).split(separator: "\n").map(String.init)
                    .filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            DispatchQueue.main.async { done(names) }
        }
    }

    static func runShortcut(_ name: String) {
        guard !name.isEmpty else { return }
        run("/usr/bin/shortcuts", ["run", name])
    }
}

/// Moves and resizes the front window (left half, fill, corners, next display…)
enum WindowSnapper {
    enum Spot { case left, right, fill, center, topLeft, topRight, bottomLeft, bottomRight }

    private static func frontWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func frame(_ w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return }
        // Size, move, size again: some apps refuse a size that doesn't fit until they've moved
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
    }

    /// Usable area (no menu bar or Dock) of each display, in top-left based coordinates
    private static func usableAreas() -> [(NSScreen, CGRect)] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { s in
            let v = s.visibleFrame
            return (s, CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height))
        }
    }

    @discardableResult
    static func snap(_ spot: Spot) -> Bool {
        guard let w = frontWindow(), let f = frame(w) else { return false }
        let areas = usableAreas()
        let center = CGPoint(x: f.midX, y: f.midY)
        guard let area = (areas.first { $0.1.contains(center) } ?? areas.first)?.1 else { return false }
        let hw = (area.width / 2).rounded(), hh = (area.height / 2).rounded()
        let r: CGRect
        switch spot {
        case .left: r = CGRect(x: area.minX, y: area.minY, width: hw, height: area.height)
        case .right: r = CGRect(x: area.minX + hw, y: area.minY, width: area.width - hw, height: area.height)
        case .fill: r = area
        case .center:
            let w2 = min(f.width, area.width * 0.8), h2 = min(f.height, area.height * 0.85)
            r = CGRect(x: area.midX - w2 / 2, y: area.midY - h2 / 2, width: w2, height: h2)
        case .topLeft: r = CGRect(x: area.minX, y: area.minY, width: hw, height: hh)
        case .topRight: r = CGRect(x: area.minX + hw, y: area.minY, width: area.width - hw, height: hh)
        case .bottomLeft: r = CGRect(x: area.minX, y: area.minY + hh, width: hw, height: area.height - hh)
        case .bottomRight: r = CGRect(x: area.minX + hw, y: area.minY + hh, width: area.width - hw, height: area.height - hh)
        }
        setFrame(w, r)
        return true
    }

    /// Moves the front window to the next display (left to right), keeping its place and proportions
    @discardableResult
    static func moveToNextDisplay() -> NSScreen? {
        guard let w = frontWindow(), let f = frame(w) else { return nil }
        let areas = usableAreas().sorted { $0.1.minX != $1.1.minX ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        guard areas.count > 1 else { return nil }
        let center = CGPoint(x: f.midX, y: f.midY)
        let i = areas.firstIndex { $0.1.contains(center) } ?? 0
        let from = areas[i].1, (screen, to) = areas[(i + 1) % areas.count]
        let sx = to.width / from.width, sy = to.height / from.height
        var r = CGRect(x: to.minX + (f.minX - from.minX) * sx, y: to.minY + (f.minY - from.minY) * sy,
                       width: f.width * sx, height: f.height * sy)
        r = r.intersection(to).isNull ? to : r
        setFrame(w, r)
        return screen
    }
}
