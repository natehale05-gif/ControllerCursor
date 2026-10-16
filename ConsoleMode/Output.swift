import AppKit

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
        e.post(tap: .cghidEventTap)
    }

    func tap(_ s: KeyShortcut) {
        key(s, down: true)
        key(s, down: false)
    }

    /// Types text into the frontmost app, whatever the keyboard layout
    func type(_ text: String) {
        var chars = Array(text.utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            e.post(tap: .cghidEventTap)
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

    func openApp(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
