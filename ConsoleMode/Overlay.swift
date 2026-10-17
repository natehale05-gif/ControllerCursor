import AppKit
import ApplicationServices

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
    /// Highlighted by D-pad navigation
    var isFocused = false { didSet { needsDisplay = true } }
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

    /// Press this key from the controller (✕ while it's highlighted)
    func activate() {
        pressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.pressed = false }
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        let hovering = self.hovering || isFocused
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
    /// Top of the keyboard on screen (so the hints can sit above it)
    var topEdge: CGFloat { panel?.frame.maxY ?? 0 }

    private let numberRow = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private let letterRows = [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                              ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                              ["z", "x", "c", "v", "b", "n", "m"]]
    private let symbolRows = [["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"],
                              ["-", "_", "=", "+", "/", "\\", ":", ";", "'", "\""],
                              ["<", ">", "[", "]", "{", "}", "~"]]

    func toggle() { isVisible ? hide() : show() }

    /// Called whenever the keyboard opens, closes, or switches between D-pad and aiming
    var onStateChange: (() -> Void)?

    func show() {
        typedBuffer = ""
        focusActive = true          // start with a key highlighted so the D-pad works right away
        layout()
        panel?.orderFrontRegardless()
        updatePreview()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.updatePreview() }
        RunLoop.main.add(t, forMode: .common)
        previewTimer = t
        onStateChange?()
    }

    func hide() {
        panel?.orderOut(nil)
        previewTimer?.invalidate()
        previewTimer = nil
        shift = false
        focusActive = false
        lastSwipe = nil
        swipePath = []
        touchedKey = nil
        swipeStart = nil
        onStateChange?()
    }

    // MARK: Text preview above the keys

    private var previewLabel: NSTextField?
    private var suggestionLabel: NSTextField?
    private var previewTimer: Timer?
    /// What's been typed with this keyboard, for apps that don't share their text
    private var typedBuffer = ""

    /// The last ~150 characters of a text box, without copying a whole long document
    private static func tailText(_ el: AXUIElement) -> String? {
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let n = countRef as? Int {
            var range = CFRange(location: max(0, n - 150), length: min(150, n))
            if let axRange = AXValueCreate(.cfRange, &range) {
                var out: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                              axRange, &out) == .success, let s = out as? String {
                    return s
                }
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let s = value as? String else { return nil }
        return String(s.suffix(150))
    }

    /// Shows the text in the box you're typing into. Reads it through Accessibility when the
    /// app allows it; otherwise shows what was typed on this keyboard. Passwords show as dots.
    private func updatePreview() {
        guard let label = previewLabel else { return }
        var text = typedBuffer
        var secure = false
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let ownAppInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        if !ownAppInFront,
           AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let el = focused as! AXUIElement
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
            secure = (subrole as? String) == (kAXSecureTextFieldSubrole as String)
            if !secure, let str = Self.tailText(el) { text = str }
        }
        if secure { text = String(repeating: "•", count: typedBuffer.count) }
        // Show the end of long text, on one line
        let oneLine = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        let tail = oneLine.count > 90 ? "…" + oneLine.suffix(89) : oneLine
        let caret = "▏"
        if tail.isEmpty {
            label.stringValue = ""
            label.placeholderString = "Start typing…"
        } else {
            label.stringValue = tail + caret
        }
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

    // MARK: D-pad navigation

    private var grid: [[KeyView]] = []
    private var focusRow = 2
    private var focusCol = 4
    /// true once the D-pad has been used; moving the pointer turns it off
    private(set) var focusActive = false

    private func applyFocus() {
        for (r, row) in grid.enumerated() {
            for (c, key) in row.enumerated() { key.isFocused = focusActive && r == focusRow && c == focusCol }
        }
    }

    enum Direction { case up, down, left, right }

    func moveFocus(_ dir: Direction) {
        guard !grid.isEmpty else { return }
        if !focusActive {
            focusActive = true
            clampFocus()
            applyFocus()
            onStateChange?()
            return
        }
        let current = grid[focusRow][focusCol].frame.midX
        switch dir {
        case .left: focusCol = (focusCol - 1 + grid[focusRow].count) % grid[focusRow].count
        case .right: focusCol = (focusCol + 1) % grid[focusRow].count
        case .up, .down:
            focusRow = (focusRow + (dir == .up ? -1 : 1) + grid.count) % grid.count
            // Land on the key most directly above/below
            let row = grid[focusRow]
            focusCol = row.indices.min { abs(row[$0].frame.midX - current) < abs(row[$1].frame.midX - current) } ?? 0
        }
        applyFocus()
    }

    /// Press the highlighted key. Returns false if nothing is highlighted.
    func activateFocused() -> Bool {
        guard focusActive, focusRow < grid.count, focusCol < grid[focusRow].count else { return false }
        let r = focusRow, c = focusCol
        grid[r][c].activate()
        return true
    }

    func clearFocus() {
        guard focusActive else { return }
        focusActive = false
        applyFocus()
        onStateChange?()
    }

    private func clampFocus() {
        focusRow = min(max(0, focusRow), max(0, grid.count - 1))
        if !grid.isEmpty { focusCol = min(max(0, focusCol), grid[focusRow].count - 1) }
    }

    private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        let u = keySize * pointRatio
        let pad = u * 0.3
        let allRows = rows()
        let rowWidths = allRows.map { $0.reduce(0) { $0 + $1.width } * u }
        let width = (rowWidths.max() ?? 0) + pad * 2
        let previewHeight = u * 0.9
        let height = CGFloat(allRows.count) * u + pad * 2 + previewHeight + pad * 0.6

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = u * 0.35
        content.layer?.masksToBounds = true

        // Preview bar across the top
        let barFrame = NSRect(x: pad + u * 0.05, y: height - pad - previewHeight,
                              width: width - pad * 2 - u * 0.1, height: previewHeight)
        let bar = NSView(frame: barFrame)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
        bar.layer?.cornerRadius = previewHeight * 0.25
        bar.layer?.borderWidth = 1
        bar.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        let fontSize = previewHeight * 0.42
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.placeholderAttributedString = NSAttributedString(string: "Start typing…", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.35)])
        let lh = fontSize * 1.35
        label.frame = NSRect(x: previewHeight * 0.35, y: (previewHeight - lh) / 2,
                             width: barFrame.width - previewHeight * 0.7, height: lh)
        bar.addSubview(label)
        let sugg = NSTextField(labelWithString: "")
        sugg.font = NSFont.systemFont(ofSize: fontSize * 0.75, weight: .regular)
        sugg.textColor = NSColor(white: 1, alpha: 0.5)
        sugg.alignment = .right
        sugg.frame = NSRect(x: barFrame.width * 0.55, y: (previewHeight - lh) / 2,
                            width: barFrame.width * 0.45 - previewHeight * 0.35, height: lh)
        bar.addSubview(sugg)
        content.addSubview(bar)
        previewLabel = label
        suggestionLabel = sugg

        grid = []
        let keysTop = height - pad - previewHeight - pad * 0.6
        for (i, row) in allRows.enumerated() {
            var x = (width - rowWidths[i]) / 2
            let y = keysTop - CGFloat(i + 1) * u
            var keys: [KeyView] = []
            for key in row {
                let v = KeyView(label: key.label, isActive: key.active, action: key.action)
                v.frame = NSRect(x: x, y: y, width: key.width * u, height: u)
                content.addSubview(v)
                keys.append(v)
                x += key.width * u
            }
            grid.append(keys)
        }
        clampFocus()
        applyFocus()
        panel.contentView = content
        updatePreview()
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

    private func typeCharacter(_ s: String, fromSwipe: Bool = false) {
        if !fromSwipe { lastSwipe = nil; showSuggestions() }
        Output.shared.type(s)
        typedBuffer += s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.updatePreview() }
        if shift && !symbols {
            shift = false
            layout()
        }
    }

    private func pressKey(_ code: CGKeyCode, keepSwipe: Bool = false) {
        if !keepSwipe, lastSwipe != nil { lastSwipe = nil; showSuggestions() }
        Output.shared.tap(KeyShortcut(keyCode: code))
        if code == 51, !typedBuffer.isEmpty { typedBuffer.removeLast() }
        if code == 36 { typedBuffer += "\n" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.updatePreview() }
    }

    // MARK: PS5-style controller shortcuts while the keyboard is open

    func typeSpace() { typeCharacter(" ") }
    func backspace() {
        // Right after a swipe, delete the whole word
        if let swipe = lastSwipe {
            for _ in 0..<(swipe.words[swipe.index].count + 1) { pressKey(51, keepSwipe: true) }
            lastSwipe = nil
            showSuggestions()
            return
        }
        pressKey(51)
    }

    // MARK: Swipe typing with the touchpad

    private var swipePath: [Character] = []
    private var touchedKey: KeyView?
    private var swipeStart: Date?
    private var lastSwipe: (words: [String], index: Int, capitalized: Bool)?

    /// Touchpad position (-1…1 both ways) while the keyboard is open; nil when the finger lifts
    func touch(_ point: CGPoint?) -> Bool {
        guard isVisible else { return false }
        guard let point else { finishSwipe(); return true }
        if swipeStart == nil { swipeStart = Date() }
        let letterRows = grid.indices.filter { $0 >= 1 && $0 <= 3 }
        let letterKeys = letterRows.flatMap { grid[$0] }
        guard let area = letterKeys.map(\.frame).reduce(nil, { (acc: CGRect?, r) in acc?.union(r) ?? r }) else { return false }
        let px = area.minX + (point.x + 1) / 2 * area.width
        let py = area.minY + (point.y + 1) / 2 * area.height
        let p = CGPoint(x: px, y: py)
        let key = letterKeys.first { $0.frame.contains(p) }
            ?? letterKeys.min { hypot($0.frame.midX - px, $0.frame.midY - py) < hypot($1.frame.midX - px, $1.frame.midY - py) }
        guard let key else { return true }
        if let r = grid.firstIndex(where: { $0.contains { $0 === key } }), let c = grid[r].firstIndex(where: { $0 === key }) {
            let wasActive = focusActive
            focusRow = r; focusCol = c; focusActive = true
            applyFocus()
            if !wasActive { onStateChange?() }
        }
        touchedKey = key
        if key.label.count == 1, let ch = key.label.lowercased().first, ch.isLetter, swipePath.last != ch {
            swipePath.append(ch)
        }
        return true
    }

    private func finishSwipe() {
        let duration = swipeStart.map { Date().timeIntervalSince($0) } ?? 0
        defer { swipePath = []; touchedKey = nil; swipeStart = nil }
        // A tap (even one that wobbles onto the next key): press that key
        guard Set(swipePath).count >= 2, swipePath.count >= 3 || duration > 0.25 else {
            touchedKey?.activate()
            return
        }
        let words = SwipeDecoder.shared.decode(swipePath)
        guard !words.isEmpty else { return }
        let cap = shift && !symbols
        lastSwipe = (words, 0, cap)
        typeCharacter(display(words[0], cap) + " ", fromSwipe: true)
        showSuggestions()
    }

    private func display(_ w: String, _ cap: Bool) -> String { cap ? w.prefix(1).uppercased() + w.dropFirst() : w }

    /// Right after a swipe, R1 swaps in the next guess
    func nextSuggestion() -> Bool {
        guard var swipe = lastSwipe, swipe.words.count > 1 else { return false }
        for _ in 0..<(swipe.words[swipe.index].count + 1) { pressKey(51, keepSwipe: true) }
        swipe.index = (swipe.index + 1) % swipe.words.count
        lastSwipe = swipe
        typeCharacter(display(swipe.words[swipe.index], swipe.capitalized) + " ", fromSwipe: true)
        showSuggestions()
        return true
    }

    private func showSuggestions() {
        guard let label = suggestionLabel else { return }
        guard let swipe = lastSwipe, swipe.words.count > 1 else { label.stringValue = ""; return }
        let others = swipe.words.enumerated().filter { $0.offset != swipe.index }.map { $0.element }
        label.stringValue = "R1: " + others.joined(separator: " · ")
    }
    func returnKey() { lastSwipe = nil; showSuggestions(); pressKey(36) }
    func cursorLeft() { lastSwipe = nil; showSuggestions(); pressKey(123) }
    func cursorRight() { pressKey(124) }
    func toggleShift() { if !symbols { shift.toggle(); layout() } }
    func toggleSymbols() { symbols.toggle(); shift = false; layout() }
}
