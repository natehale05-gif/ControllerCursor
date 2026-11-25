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

    /// Bounds of all screens in global (top-left origin) coordinates
    private func clamp(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let rects = ids.map { CGDisplayBounds($0) }
        if rects.contains(where: { $0.contains(p) }) { return p }
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

    func movePointer(dx: CGFloat, dy: CGFloat) {
        remainder.x += dx
        remainder.y += dy
        let ix = remainder.x.rounded(.towardZero)
        let iy = remainder.y.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        remainder.x -= ix
        remainder.y -= iy
        let current = Self.pointerLocation()
        let target = clamp(CGPoint(x: current.x + ix, y: current.y + iy))
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target,
                              mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        if leftDown { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
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
    func openSiri(failed: @escaping (String) -> Void) {
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
