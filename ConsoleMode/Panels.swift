import AppKit
import SwiftUI

private func makeOverlayPanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.level = .statusBar
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return p
}

// MARK: - Quick Menu wheel

/// Hold L2 and point the right stick at a slice; let go of L2 to run it
final class QuickWheel {
    private let panel = makeOverlayPanel()
    private let view = WheelView()
    private(set) var isVisible = false

    init() {
        panel.ignoresMouseEvents = true
        panel.contentView = view
    }

    func show(_ items: [ActionKind], scale: CGFloat) {
        view.items = items
        view.selected = nil
        let size = 380 * scale
        guard let screen = NSScreen.withPointer else { return }
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - size / 2, y: f.midY - size / 2, width: size, height: size), display: true)
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        if !isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
        isVisible = true
    }

    /// Right stick position; returns true when the highlighted slice changed
    func aim(x: Float, y: Float) -> Bool {
        guard isVisible, !view.items.isEmpty, hypot(x, y) > 0.5 else { return false }
        var angle = atan2(Double(x), Double(y))          // 0 = up, clockwise
        if angle < 0 { angle += 2 * .pi }
        let slice = 2 * Double.pi / Double(view.items.count)
        let i = Int((angle / slice).rounded()) % view.items.count
        guard i != view.selected else { return false }
        view.selected = i
        return true
    }

    /// Closes the wheel and returns the slice that was picked
    func hide() -> ActionKind? {
        guard isVisible else { return nil }
        isVisible = false
        let picked = view.selected.map { view.items[$0] }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                            completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        })
        return picked
    }
}

final class WheelView: NSView {
    var items: [ActionKind] = [] { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = bounds.width / 2 - 6, inner = outer * 0.36
        // Background disc
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        NSColor(white: 0.08, alpha: 0.82).setFill()
        disc.fill()
        NSColor(white: 1, alpha: 0.15).setStroke()
        disc.lineWidth = 1.5
        disc.stroke()
        guard !items.isEmpty else { return }
        let n = items.count
        let slice = 360.0 / Double(n)
        for (i, item) in items.enumerated() {
            // Slice i is centred on angle i*slice, clockwise from the top
            let mid = 90 - Double(i) * slice
            if i == selected {
                let path = NSBezierPath()
                path.appendArc(withCenter: c, radius: outer - 4, startAngle: CGFloat(mid - slice / 2 + 1),
                               endAngle: CGFloat(mid + slice / 2 - 1))
                path.appendArc(withCenter: c, radius: inner, startAngle: CGFloat(mid + slice / 2 - 1),
                               endAngle: CGFloat(mid - slice / 2 + 1), clockwise: true)
                path.close()
                NSColor(calibratedRed: 0.0, green: 0.44, blue: 0.95, alpha: 0.95).setFill()
                path.fill()
            }
            let r = (outer + inner) / 2
            let rad = mid * .pi / 180
            let p = NSPoint(x: c.x + CGFloat(cos(rad)) * r, y: c.y + CGFloat(sin(rad)) * r)
            let iconSize = outer * 0.17
            if let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold)) {
                let tinted = img.tinted(.white)
                let s = tinted.size
                tinted.draw(in: NSRect(x: p.x - s.width / 2, y: p.y - s.height / 2 + iconSize * 0.45, width: s.width, height: s.height))
            }
            let label = NSAttributedString(string: item.shortTitle, attributes: [
                .font: NSFont.systemFont(ofSize: outer * 0.065, weight: .semibold),
                .foregroundColor: NSColor.white])
            let ls = label.size()
            label.draw(at: NSPoint(x: p.x - ls.width / 2, y: p.y - iconSize * 0.95))
        }
        // Centre: what's picked
        let title = selected.map { items[$0].title } ?? "Point the right stick"
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: inner * 0.16, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: selected == nil ? 0.5 : 1)])
        let rect = NSRect(x: c.x - inner * 0.85, y: c.y - inner * 0.4, width: inner * 1.7, height: inner * 0.8)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let m = NSMutableAttributedString(attributedString: t)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        let h = m.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
        m.draw(with: NSRect(x: rect.minX, y: c.y - h / 2, width: rect.width, height: h), options: [.usesLineFragmentOrigin])
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}

// MARK: - Control Center

/// PS5-style panel: volume, brightness, Wi-Fi, media, power — driven by the controller
final class ControlCenter: ObservableObject {
    enum Tile: Hashable {
        case volume, brightness, wifi, darkMode, screenshot, keyboard
        case previous, playPause, next
        case lock, sleep, displayOff, settings
    }

    let rows: [[Tile]] = [[.volume], [.brightness], [.wifi, .darkMode, .screenshot, .keyboard],
                          [.previous, .playPause, .next], [.lock, .sleep, .displayOff, .settings]]
    static let powerRow = 4

    @Published var row = 0
    @Published var col = 0
    @Published var volume = 50
    @Published var muted = false
    @Published var wifi: Bool?
    @Published var dark = false
    @Published var time = ""
    @Published var macBattery: String?
    @Published var controllerBattery: String?

    var controllerBatteryLevel: () -> (Float, Bool)? = { nil }
    var perform: (ActionKind) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var onClose: () -> Void = {}

    private var panel: NSPanel?
    private var timer: Timer?
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(powerRow: Bool = false) { isVisible && !powerRow ? hide() : show(powerRow: powerRow) }

    func show(powerRow: Bool = false) {
        refresh()
        row = powerRow ? Self.powerRow : 0
        col = 0
        let p = panel ?? makeOverlayPanel()
        panel = p
        let host = NSHostingView(rootView: ControlCenterView(cc: self))
        let size = NSSize(width: 520, height: 470)
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        guard let screen = NSScreen.withPointer else { return }
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.maxX - size.width - 24, y: f.maxY - size.height - 16, width: size.width, height: size.height),
                   display: true)
        p.orderFrontRegardless()
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        onClose()
    }

    func refresh() {
        volume = SystemControls.volume
        muted = SystemControls.isMuted
        wifi = SystemControls.wifiOn
        dark = SystemControls.darkMode
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        time = f.string(from: Date())
        macBattery = SystemControls.macBattery.map { "\($0.0)%" + ($0.1 ? " ⚡︎" : "") }
        controllerBattery = controllerBatteryLevel().map { "\(Int($0.0 * 100))%" + ($0.1 ? " ⚡︎" : "") }
    }

    /// Controller buttons while it's open. Returns true when handled.
    func handle(_ button: PadButton) -> Bool {
        switch button {
        case .up: move(rows: -1)
        case .down: move(rows: 1)
        case .left: horizontal(-1)
        case .right: horizontal(1)
        case .cross: activate(rows[row][col])
        case .circle, .triangle, .ps, .options: hide()
        case .l1: horizontal(-1)
        case .r1: horizontal(1)
        default: return true   // swallow everything else while it's open
        }
        return true
    }

    private func move(rows d: Int) {
        row = (row + d + rows.count) % rows.count
        col = min(col, rows[row].count - 1)
    }

    private func horizontal(_ d: Int) {
        switch rows[row][col] {
        case .volume:
            SystemControls.setVolume(volume + d * 6)
            volume = SystemControls.volume
            muted = false
        case .brightness:
            perform(d > 0 ? .brightnessUp : .brightnessDown)
        default:
            col = (col + d + rows[row].count) % rows[row].count
        }
    }

    func activate(_ tile: Tile) {
        switch tile {
        case .volume: SystemControls.toggleMute(); muted = SystemControls.isMuted
        case .brightness: perform(.brightnessUp)
        case .wifi: SystemControls.toggleWiFi(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.wifi = SystemControls.wifiOn }
        case .darkMode: SystemControls.toggleDarkMode(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.dark = SystemControls.darkMode }
        case .screenshot: hide(); perform(.captureMenu)
        case .keyboard: hide(); perform(.keyboard)
        case .previous: perform(.previousTrack)
        case .playPause: perform(.playPause)
        case .next: perform(.nextTrack)
        case .lock: hide(); SystemControls.lock()
        case .sleep: hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SystemControls.sleep() }
        case .displayOff: hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SystemControls.displaySleep() }
        case .settings: hide(); openSettings()
        }
    }

    func isFocused(_ tile: Tile) -> Bool { rows[row][col] == tile }
}

struct ControlCenterView: View {
    @ObservedObject var cc: ControlCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(cc.time).font(.system(size: 26, weight: .semibold, design: .rounded))
                Spacer()
                if let b = cc.controllerBattery { badge("gamecontroller.fill", b) }
                if let b = cc.macBattery { badge("laptopcomputer", b) }
            }
            slider(.volume, icon: cc.muted || cc.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   title: cc.muted ? "Muted" : "Volume", value: cc.muted ? 0 : Double(cc.volume) / 100)
            slider(.brightness, icon: "sun.max.fill", title: "Brightness", value: nil)
            HStack(spacing: 10) {
                tile(.wifi, icon: "wifi", title: cc.wifi == false ? "Wi-Fi Off" : "Wi-Fi", on: cc.wifi == true)
                tile(.darkMode, icon: "circle.lefthalf.filled", title: "Dark Mode", on: cc.dark)
                tile(.screenshot, icon: "camera.viewfinder", title: "Screenshot")
                tile(.keyboard, icon: "keyboard", title: "Keyboard")
            }
            HStack(spacing: 10) {
                tile(.previous, icon: "backward.fill", title: "Previous")
                tile(.playPause, icon: "playpause.fill", title: "Play / Pause")
                tile(.next, icon: "forward.fill", title: "Next")
            }
            HStack(spacing: 10) {
                tile(.lock, icon: "lock.fill", title: "Lock")
                tile(.sleep, icon: "moon.fill", title: "Sleep")
                tile(.displayOff, icon: "display", title: "Display Off")
                tile(.settings, icon: "gearshape.fill", title: "Settings")
            }
            Text("D-pad to move · ←/→ adjust · ✕ select · ○ close")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 26)))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.12)))
    }

    private func badge(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) { Image(systemName: icon); Text(text) }
            .font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.12)))
    }

    private func slider(_ t: ControlCenter.Tile, icon: String, title: String, value: Double?) -> some View {
        let focused = cc.isFocused(t)
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                if let value {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            Capsule().fill(.white).frame(width: max(8, g.size.width * value))
                        }
                    }.frame(height: 8)
                } else {
                    Text("← dimmer   brighter →").font(.caption).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(focused ? Color.accentColor.opacity(0.9) : .white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { cc.activate(t) }
    }

    private func tile(_ t: ControlCenter.Tile, icon: String, title: String, on: Bool = false) -> some View {
        let focused = cc.isFocused(t)
        return VStack(spacing: 6) {
            Image(systemName: icon).font(.title2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(on ? Color.accentColor : .white.opacity(0.14)))
            Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(focused ? Color.accentColor.opacity(0.9) : .white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { cc.activate(t) }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
