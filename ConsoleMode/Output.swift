import AppKit
import Carbon

/// Everything Console Mode sends to macOS: pointer, clicks, scrolling and keys.
final class Output {
    static let shared = Output()

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var leftDown = false
    private var lastClickTime = Date.distantPast
    private var lastClickPoint = CGPoint.zero
    private var clickCount = 1
    /// When we last moved the pointer ourselves (so the app can tell controller from mouse)
    private(set) var lastPointerPost = Date.distantPast
    private var remainder = CGPoint.zero

    var hasPermission: Bool { CGPreflightPostEventAccess() }

    // MARK: Pointer

    static func pointerLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Cross to a neighbouring display anywhere along the shared side, even where the edges don't line up
    var crossAnyEdge = true

    private static func displayRects() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        // Mirrored displays share one spot; count it once
        return ids.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map { CGDisplayBounds($0) }
    }

    /// Where the pointer should end up when moving from `from` toward `p`
    private func clamp(_ p: CGPoint, from: CGPoint? = nil) -> CGPoint {
        let rects = Self.displayRects()
        if rects.contains(where: { $0.contains(p) }) { return p }
        if crossAnyEdge, let from, let here = rects.first(where: { $0.contains(from) }),
           let crossed = cross(from: here, toward: p, rects: rects) {
            return crossed
        }
        // Snap to the closest point on the nearest screen
        var best = p
        var bestDist = CGFloat.greatestFiniteMagnitude
        for r in rects {
            let c = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < bestDist { bestDist = d; best = c }
        }
        return best
    }

    /// Pushing past a side of the current display lands on the display beyond it, at the same
    /// relative height (or width), like moving between monitors on a console's multi-screen setup.
    private func cross(from here: CGRect, toward p: CGPoint, rects: [CGRect]) -> CGPoint? {
        let others = rects.filter { $0 != here }
        func relY(_ r: CGRect) -> CGFloat { r.minY + (min(max(p.y, here.minY), here.maxY - 1) - here.minY) / here.height * r.height }
        func relX(_ r: CGRect) -> CGFloat { r.minX + (min(max(p.x, here.minX), here.maxX - 1) - here.minX) / here.width * r.width }
        func overlaps(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { min(b, d) - max(a, c) }
        if p.x >= here.maxX || p.x < here.minX {
            let right = p.x >= here.maxX
            let side = others.filter { right ? $0.minX >= here.maxX - 1 : $0.maxX <= here.minX + 1 }
            // Nearest display on that side, preferring the one that shares the most of this edge
            guard let r = side.min(by: {
                let ga = right ? $0.minX - here.maxX : here.minX - $0.maxX
                let gb = right ? $1.minX - here.maxX : here.minX - $1.maxX
                if abs(ga - gb) > 1 { return ga < gb }
                return overlaps($0.minY, $0.maxY, here.minY, here.maxY) > overlaps($1.minY, $1.maxY, here.minY, here.maxY)
            }) else { return nil }
            let y = r.contains(CGPoint(x: r.midX, y: p.y)) ? p.y : relY(r)
            return CGPoint(x: right ? r.minX : r.maxX - 1, y: min(max(y, r.minY), r.maxY - 1))
        }
        if p.y >= here.maxY || p.y < here.minY {
            let down = p.y >= here.maxY
            let side = others.filter { down ? $0.minY >= here.maxY - 1 : $0.maxY <= here.minY + 1 }
            guard let r = side.min(by: {
                let ga = down ? $0.minY - here.maxY : here.minY - $0.maxY
                let gb = down ? $1.minY - here.maxY : here.minY - $1.maxY
                if abs(ga - gb) > 1 { return ga < gb }
                return overlaps($0.minX, $0.maxX, here.minX, here.maxX) > overlaps($1.minX, $1.maxX, here.minX, here.maxX)
            }) else { return nil }
            let x = r.contains(CGPoint(x: p.x, y: r.midY)) ? p.x : relX(r)
            return CGPoint(x: min(max(x, r.minX), r.maxX - 1), y: down ? r.minY : r.maxY - 1)
        }
        return nil
    }

    /// For the Mac's own mouse or trackpad: when it's pushing against a side with no display directly
    /// next to it, where it should jump to instead (nil to leave it alone)
    func crossTarget(at loc: CGPoint, dx: CGFloat, dy: CGFloat) -> CGPoint? {
        guard crossAnyEdge, dx != 0 || dy != 0 else { return nil }
        let rects = Self.displayRects()
        guard rects.count > 1, let here = rects.first(where: { $0.contains(loc) }) else { return nil }
        let push = CGPoint(x: loc.x + (dx > 0 ? 2 : dx < 0 ? -2 : 0), y: loc.y + (dy > 0 ? 2 : dy < 0 ? -2 : 0))
        guard !rects.contains(where: { $0.contains(push) }) else { return nil }
        // Only when it's actually up against the edge
        let atEdge = (dx > 0 && loc.x >= here.maxX - 1.5) || (dx < 0 && loc.x <= here.minX + 0.5)
            || (dy > 0 && loc.y >= here.maxY - 1.5) || (dy < 0 && loc.y <= here.minY + 0.5)
        guard atEdge else { return nil }
        return cross(from: here, toward: push, rects: rects)
    }

    func movePointer(dx: CGFloat, dy: CGFloat) {
        remainder.x += dx
        remainder.y += dy
        let ix = remainder.x.rounded(.towardZero)
        let iy = remainder.y.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        remainder.x -= ix
        remainder.y -= iy
        let current = Self.pointerLocation()
        let target = clamp(CGPoint(x: current.x + ix, y: current.y + iy), from: current)
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target,
                              mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        if leftDown { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        e.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        e.post(tap: .cghidEventTap)
        lastPointerPost = Date()
    }

    /// Puts the pointer exactly on a spot (used to jump to buttons and links)
    func movePointer(to point: CGPoint) {
        let target = clamp(point)
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target,
                              mouseButton: .left) else { return }
        let current = Self.pointerLocation()
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(target.x - current.x))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(target.y - current.y))
        e.post(tap: .cghidEventTap)
        remainder = .zero
        lastPointerPost = Date()
    }

    // MARK: Clicks

    func leftButton(down: Bool) {
        let p = Self.pointerLocation()
        if down {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval,
               hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 6 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickPoint = p
        }
        leftDown = down
        post(down ? .leftMouseDown : .leftMouseUp, button: .left, at: p, clicks: clickCount)
    }

    func rightClick() {
        let p = Self.pointerLocation()
        post(.rightMouseDown, button: .right, at: p, clicks: 1)
        post(.rightMouseUp, button: .right, at: p, clicks: 1)
    }

    func middleClick() {
        let p = Self.pointerLocation()
        post(.otherMouseDown, button: .center, at: p, clicks: 1)
        post(.otherMouseUp, button: .center, at: p, clicks: 1)
    }

    private func post(_ type: CGEventType, button: CGMouseButton, at p: CGPoint, clicks: Int) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }

    // MARK: Scrolling

    private var scrollRemainder = CGPoint.zero

    func scroll(dx: CGFloat, dy: CGFloat) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let ix = scrollRemainder.x.rounded(.towardZero), iy = scrollRemainder.y.rounded(.towardZero)
        guard ix != 0 || iy != 0,
              let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0)
        else { return }
        scrollRemainder.x -= ix
        scrollRemainder.y -= iy
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keys

    func key(_ s: KeyShortcut, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: s.keyCode, keyDown: down) else { return }
        // Real arrow and F-keys carry the fn flag; system shortcuts like Mission Control need it to match
        var f = s.flags
        switch s.keyCode {
        case 123...126: f.formUnion([.maskSecondaryFn, .maskNumericPad])
        case 96...122: f.insert(.maskSecondaryFn)
        default: break
        }
        e.flags = f
        e.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        e.post(tap: .cghidEventTap)
    }

    func tap(_ s: KeyShortcut) {
        key(s, down: true)
        key(s, down: false)
    }

    /// Marks events Console Mode posts, so the keyboard preview can tell them from the Mac keyboard
    static let eventTag: Int64 = 0x434D4F44   // "CMOD"

    /// Types text into the frontmost app as real key presses on the current keyboard layout, so the
    /// app treats it exactly like typing: autocorrect, text replacements, predictions and games all work.
    /// Characters the layout can't type (emoji, some accents) are sent as text.
    func type(_ text: String) {
        for ch in text {
            if let k = KeyLayout.shared.key(for: ch) {
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: k.code, keyDown: down) else { continue }
                    var f: CGEventFlags = []
                    if k.shift { f.insert(.maskShift) }
                    if k.option { f.insert(.maskAlternate) }
                    e.flags = f
                    e.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                    e.post(tap: .cghidEventTap)
                }
            } else {
                var u = Array(String(ch).utf16)
                // Apps only read up to 20 UTF-16 units per key event
                guard u.count <= 20 else { continue }
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    e.flags = []
                    e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                    e.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                    e.post(tap: .cghidEventTap)
                }
            }
        }
    }

    // MARK: Media keys (volume, brightness, play/pause)

    enum MediaKey: Int32 {
        case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        case play = 16, next = 17, previous = 18
    }

    func media(_ key: MediaKey) {
        for down in [true, false] {
            let flags: Int = down ? 0xA00 : 0xB00
            let data1 = (Int(key.rawValue) << 16) | flags
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Apps

    /// Opens Siri the same way the Siri key does. `failed` gets a reason to show if it can't.
    /// When Siri was last opened; macOS sends Console Mode a "reopen" afterwards that isn't the user's
    private(set) var lastSiriOpen = Date.distantPast

    func openSiri(failed: @escaping (String) -> Void) {
        lastSiriOpen = Date()
        let fm = FileManager.default
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Siri")
            ?? ["/System/Applications/Siri.app", "/Applications/Siri.app"].map { URL(fileURLWithPath: $0) }
                .first { fm.fileExists(atPath: $0.path) }
        guard let url else { failed("Siri isn't available on this Mac"); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { failed("Couldn't open Siri. Turn it on in System Settings → Apple Intelligence & Siri") }
        }
    }

    func openApp(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Which key (and Shift/Option) types each character on the Mac's current keyboard layout
final class KeyLayout {
    static let shared = KeyLayout()
    struct Key { let code: CGKeyCode; let shift: Bool; let option: Bool }
    private var map: [Character: Key] = [:]

    private init() {
        rebuild()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    func key(for ch: Character) -> Key? { map[ch] }

    private func rebuild() {
        var m: [Character: Key] = [" ": Key(code: 49, shift: false, option: false),
                                   "\n": Key(code: 36, shift: false, option: false),
                                   "\r": Key(code: 36, shift: false, option: false),
                                   "\t": Key(code: 48, shift: false, option: false)]
        defer { map = m }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let kbType = UInt32(LMGetKbdType())
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Plain first, so the simplest way to type a character wins
            let combos: [(UInt32, Bool, Bool)] = [(0, false, false), (2, true, false), (8, false, true), (10, true, true)]
            for (mods, shift, option) in combos {
                // Main typing keys only (not the keypad, function keys, return, tab, space or delete)
                for code in 0...50 where ![36, 48, 49].contains(code) {
                    var dead: UInt32 = 0
                    var len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, kbType,
                                                0, &dead, chars.count, &len, &chars)
                    // Skip dead keys (like Option-E), which wait for another key
                    guard status == noErr, dead == 0, len > 0 else { continue }
                    let str = String(utf16CodeUnits: chars, count: len)
                    guard str.count == 1, let ch = str.first, m[ch] == nil,
                          !(ch.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? true)
                    else { continue }
                    m[ch] = Key(code: CGKeyCode(code), shift: shift, option: option)
                }
            }
        }
    }
}
