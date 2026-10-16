import AppKit
import ApplicationServices

/// Moves the pointer between clickable things (buttons, links, text boxes…) with the D-pad,
/// using the same Accessibility information VoiceOver uses.
final class SnapNavigator {
    enum Direction { case up, down, left, right }

    private var cached: [CGRect] = []
    private var cachedAt = Date.distantPast
    private var cachedPID: pid_t = 0
    private var enabledPIDs: Set<pid_t> = []

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle",
        "AXSlider", "AXIncrementor", "AXMenuBarItem", "AXCell", "AXRow", "AXImage", "AXDockItem",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    /// True when a text box has focus — then the D-pad should move the text cursor instead
    func focusedIsTextInput() -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let el = copyElement(system, kAXFocusedUIElementAttribute) else { return false }
        return Self.textRoles.contains(string(el, kAXRoleAttribute) ?? "")
    }

    /// Jumps toward the nearest clickable thing in that direction. Returns false if there isn't one.
    func jump(_ dir: Direction) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        if pid != cachedPID || Date().timeIntervalSince(cachedAt) > 0.6 {
            cached = collectTargets(pid: pid)
            cachedPID = pid
            cachedAt = Date()
        }
        let p = Output.pointerLocation()
        var best: (CGRect, CGFloat)?
        for r in cached {
            let c = CGPoint(x: r.midX, y: r.midY)
            if r.contains(p) { continue }
            let dx = c.x - p.x, dy = c.y - p.y
            let (primary, secondary): (CGFloat, CGFloat)
            switch dir {
            case .right: (primary, secondary) = (dx, dy)
            case .left: (primary, secondary) = (-dx, dy)
            case .down: (primary, secondary) = (dy, dx)
            case .up: (primary, secondary) = (-dy, dx)
            }
            guard primary > 6, abs(secondary) < primary * 2.5 + 40 else { continue }
            let score = primary + abs(secondary) * 2.2
            if best == nil || score < best!.1 { best = (r, score) }
        }
        guard let target = best?.0 else { return false }
        Output.shared.movePointer(to: CGPoint(x: target.midX, y: target.midY))
        return true
    }

    // MARK: Accessibility tree walk

    private func collectTargets(pid: pid_t) -> [CGRect] {
        let appEl = AXUIElementCreateApplication(pid)
        // Chrome, Electron and similar only build their accessibility tree when asked
        if !enabledPIDs.contains(pid) {
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPIDs.insert(pid)
        }
        var roots: [AXUIElement] = []
        if let win = copyElement(appEl, kAXFocusedWindowAttribute) { roots.append(win) }
        if let sheet = copyElement(appEl, "AXFocusedUIElement"), roots.isEmpty { roots.append(sheet) }
        let screens = NSScreen.screens.map { s -> CGRect in
            let maxY = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(x: s.frame.minX, y: maxY - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        let screenArea = screens.map { $0.width * $0.height }.max() ?? 1

        var results: [CGRect] = []
        var queue = roots
        var visited = 0
        let deadline = Date().addingTimeInterval(0.12)
        while !queue.isEmpty, visited < 3000, Date() < deadline {
            let el = queue.removeFirst()
            visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if Self.clickableRoles.contains(role), let r = frame(el),
               r.width >= 6, r.height >= 6, r.width * r.height < screenArea * 0.4,
               screens.contains(where: { $0.intersects(r) }) {
                if role != "AXImage" && role != "AXRow" && role != "AXCell" || hasPress(el) {
                    results.append(r)
                }
            }
            if let kids = children(el) { queue.append(contentsOf: kids) }
        }
        return results
    }

    private func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func children(_ el: AXUIElement) -> [AXUIElement]? {
        var v: CFTypeRef?
        let attr = string(el, kAXRoleAttribute) == "AXWebArea" ? "AXVisibleChildren" : kAXChildrenAttribute
        if AXUIElementCopyAttributeValue(el, attr as CFString, &v) != .success {
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return nil }
        }
        return v as? [AXUIElement]
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func hasPress(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }
}
