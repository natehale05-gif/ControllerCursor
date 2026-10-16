import AppKit

// MARK: - Circle drawn around the pointer

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


// MARK: - Bigger screen while using the controller

final class DisplayScaler {
    private var originalMode: CGDisplayMode?
    private var display: CGDirectDisplayID = CGMainDisplayID()
    private(set) var isScaled = false

    /// factor < 1 makes everything bigger (0.85 ≈ one step, 0.72 ≈ two steps)
    func scaleUp(factor: Double) -> Bool {
        guard !isScaled, factor < 1 else { return false }
        display = CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(display) else { return false }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode] else { return false }
        let hiDPI = current.pixelWidth > current.width
        let aspect = Double(current.width) / Double(current.height)
        let target = Double(current.width) * factor
        let candidates = all.filter { m in
            m.isUsableForDesktopGUI() && m.width < current.width && m.height > 0 &&
            abs(Double(m.width) / Double(m.height) - aspect) < 0.02 &&
            (m.pixelWidth > m.width) == hiDPI
        }
        func score(_ m: CGDisplayMode) -> (Double, Double) {
            (abs(Double(m.width) - target), abs(m.refreshRate - current.refreshRate))
        }
        guard let best = candidates.min(by: { score($0) < score($1) }) else { return false }
        guard apply(best) else { return false }
        originalMode = current
        isScaled = true
        return true
    }

    /// Points shrink when the screen is scaled up; multiply sizes by this to keep them physically the same
    var pointRatio: CGFloat {
        guard isScaled, let originalMode, let current = CGDisplayCopyDisplayMode(display),
              originalMode.width > 0 else { return 1 }
        return CGFloat(current.width) / CGFloat(originalMode.width)
    }

    @discardableResult
    func restore() -> Bool {
        guard isScaled, let originalMode else { return false }
        isScaled = false
        return apply(originalMode)
    }

    private func apply(_ mode: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}


// MARK: - Controller keyboard

final class KeyView: NSView {
    let label: String
    var isActive = false { didSet { needsDisplay = true } }
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(label: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isActive = isActive
        self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        if wasPressed { action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: bounds.height * 0.05, dy: bounds.height * 0.05)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.22, yRadius: rect.height * 0.22)
        let blue = NSColor(calibratedRed: 0.0, green: 0.44, blue: 0.95, alpha: 1)
        let fill: NSColor = pressed ? .white : hovering ? blue : isActive ? NSColor(white: 0.42, alpha: 1)
                                                                          : NSColor(white: 0.20, alpha: 1)
        fill.setFill()
        path.fill()
        if hovering && !pressed {
            NSColor.white.setStroke()
            path.lineWidth = max(2, rect.height * 0.04)
            path.stroke()
        }
        let fontSize = rect.height * (label.count > 3 ? 0.26 : label.count > 1 ? 0.32 : 0.44)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: pressed ? NSColor.black : NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

final class ControllerKeyboard {
    private var panel: NSPanel?
    private var shift = false
    private var symbols = false
    /// Key size in points at the normal screen size
    var keySize: CGFloat = 64
    /// Multiplier that keeps the physical size constant when the screen is scaled up
    var pointRatio: CGFloat = 1

    var isVisible: Bool { panel?.isVisible ?? false }

    private let numberRow = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private let letterRows = [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                              ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                              ["z", "x", "c", "v", "b", "n", "m"]]
    private let symbolRows = [["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"],
                              ["-", "_", "=", "+", "/", "\\", ":", ";", "'", "\""],
                              ["<", ">", "[", "]", "{", "}", "~"]]

    func toggle() { isVisible ? hide() : show() }

    func show() {
        layout()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        shift = false
    }

    /// Re-lay out at the current screen size (call after the display scale changes)
    func refresh() { if isVisible { layout() } }

    // MARK: Layout

    private struct Key { let label: String; let width: CGFloat; let active: Bool; let action: () -> Void }

    private func rows() -> [[Key]] {
        func ch(_ s: String) -> Key {
            let shown = (shift && !symbols) ? s.uppercased() : s
            return Key(label: shown, width: 1, active: false) { [weak self] in self?.typeCharacter(shown) }
        }
        func special(_ label: String, _ w: CGFloat, active: Bool = false, _ a: @escaping () -> Void) -> Key {
            Key(label: label, width: w, active: active, action: a)
        }
        let body = symbols ? symbolRows : letterRows
        var r: [[Key]] = []
        r.append(numberRow.map(ch) + [special("⌫", 1.5) { [weak self] in self?.pressKey(51) }])
        r.append(body[0].map(ch))
        r.append(body[1].map(ch) + [special("return", 1.75) { [weak self] in self?.pressKey(36) }])
        var row3: [Key] = []
        if symbols {
            row3.append(special("tab", 1.5) { [weak self] in self?.pressKey(48) })
        } else {
            row3.append(special("⇧", 1.5, active: shift) { [weak self] in
                guard let self else { return }
                self.shift.toggle(); self.layout()
            })
        }
        row3 += body[2].map(ch) + [ch(","), ch("."), ch("?")]
        r.append(row3)
        r.append([
            special(symbols ? "ABC" : "#+=", 1.5, active: symbols) { [weak self] in
                guard let self else { return }
                self.symbols.toggle(); self.shift = false; self.layout()
            },
            special("@", 1) { [weak self] in self?.typeCharacter("@") },
            special("space", 5) { [weak self] in self?.typeCharacter(" ") },
            special("←", 1) { [weak self] in self?.pressKey(123) },
            special("→", 1) { [weak self] in self?.pressKey(124) },
            special("done", 1.5) { [weak self] in self?.hide() },
        ])
        return r
    }

    private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        let u = keySize * pointRatio
        let pad = u * 0.3
        let allRows = rows()
        let rowWidths = allRows.map { $0.reduce(0) { $0 + $1.width } * u }
        let width = (rowWidths.max() ?? 0) + pad * 2
        let height = CGFloat(allRows.count) * u + pad * 2

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = u * 0.35
        content.layer?.masksToBounds = true

        for (i, row) in allRows.enumerated() {
            var x = (width - rowWidths[i]) / 2
            let y = height - pad - CGFloat(i + 1) * u
            for key in row {
                let v = KeyView(label: key.label, isActive: key.active, action: key.action)
                v.frame = NSRect(x: x, y: y, width: key.width * u, height: u)
                content.addSubview(v)
                x += key.width * u
            }
        }
        panel.contentView = content
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.minY + u * 0.4, width: width, height: height),
                       display: true)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return p
    }

    // MARK: Typing into the app you're using

    private func typeCharacter(_ s: String) {
        Output.shared.type(s)
        if shift && !symbols {
            shift = false
            layout()
        }
    }

    private func pressKey(_ code: CGKeyCode) {
        Output.shared.tap(KeyShortcut(keyCode: code))
    }

    // MARK: PS5-style controller shortcuts while the keyboard is open

    func typeSpace() { typeCharacter(" ") }
    func backspace() { pressKey(51) }
    func returnKey() { pressKey(36) }
    func cursorLeft() { pressKey(123) }
    func cursorRight() { pressKey(124) }
    func toggleShift() { if !symbols { shift.toggle(); layout() } }
    func toggleSymbols() { symbols.toggle(); shift = false; layout() }
}
