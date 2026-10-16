import AppKit

/// A borderless, click-through panel that floats above everything
private func makeHUDPanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.ignoresMouseEvents = true
    p.level = .statusBar
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return p
}

private func blurBackground(_ size: NSSize, radius: CGFloat) -> NSVisualEffectView {
    let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    v.wantsLayer = true
    v.layer?.cornerRadius = radius
    v.layer?.masksToBounds = true
    return v
}

// MARK: - Button hints along the bottom of the screen

/// "✕ Select  ○ Back  △ Keyboard" — like the prompts at the bottom of a console screen
final class HintsBar {
    private let panel = makeHUDPanel()
    private var hideWork: DispatchWorkItem?
    private(set) var shown = false
    var scale: CGFloat = 1

    func show(_ items: [(glyph: String, color: NSColor, title: String)], autoHideAfter: TimeInterval?) {
        guard let screen = NSScreen.screens.first, !items.isEmpty else { return }
        let fontSize: CGFloat = 15 * scale
        let glyphFont = NSFont.systemFont(ofSize: fontSize * 1.05, weight: .bold)
        let textFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let line = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            if i > 0 { line.append(NSAttributedString(string: "     ", attributes: [.font: textFont])) }
            line.append(NSAttributedString(string: item.glyph, attributes: [.font: glyphFont, .foregroundColor: item.color]))
            line.append(NSAttributedString(string: "  " + item.title, attributes: [
                .font: textFont, .foregroundColor: NSColor.white]))
        }
        let label = NSTextField(labelWithAttributedString: line)
        label.sizeToFit()
        let padX = 22 * scale, padY = 10 * scale
        let size = NSSize(width: label.frame.width + padX * 2, height: label.frame.height + padY * 2)
        let bg = blurBackground(size, radius: size.height / 2)
        label.frame.origin = NSPoint(x: padX, y: padY)
        bg.addSubview(label)
        panel.contentView = bg
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 18 * scale,
                              width: size.width, height: size.height), display: true)
        if !shown {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
            shown = true
        }
        hideWork?.cancel()
        if let delay = autoHideAfter {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    func hide() {
        hideWork?.cancel()
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                            completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
        })
    }
}

// MARK: - Toasts (connected, battery low, paused for a game…)

final class Toast {
    private let panel = makeHUDPanel()
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String, tint: NSColor = .white, duration: TimeInterval = 2.6) {
        guard let screen = NSScreen.screens.first else { return }
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.sizeToFit()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.contentTintColor = tint
        let h: CGFloat = 46
        let w = label.frame.width + 18 + 26 + 34
        let bg = blurBackground(NSSize(width: w, height: h), radius: h / 2)
        icon.frame = NSRect(x: 18, y: (h - 24) / 2, width: 24, height: 24)
        label.frame.origin = NSPoint(x: 18 + 26 + 8, y: (h - label.frame.height) / 2)
        bg.addSubview(icon)
        bg.addSubview(label)
        panel.contentView = bg
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 14, width: w, height: h), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.panel.animator().alphaValue = 0 },
                                                completionHandler: { self.panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

// MARK: - Voice typing caption

final class VoiceCaption {
    private let panel = makeHUDPanel()
    private var label: NSTextField?

    func update(_ text: String?) {
        guard let text else { panel.orderOut(nil); return }
        guard let screen = NSScreen.screens.first else { return }
        let shown = text.isEmpty ? "Listening…" : text
        let w: CGFloat = min(760, screen.visibleFrame.width - 80), h: CGFloat = 64
        let bg = blurBackground(NSSize(width: w, height: h), radius: 20)
        let mic = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) ?? NSImage())
        mic.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        mic.contentTintColor = .systemRed
        mic.frame = NSRect(x: 20, y: (h - 28) / 2, width: 28, height: 28)
        let l = NSTextField(labelWithString: shown)
        l.font = NSFont.systemFont(ofSize: 19, weight: .medium)
        l.textColor = text.isEmpty ? NSColor(white: 1, alpha: 0.5) : .white
        l.lineBreakMode = .byTruncatingHead
        l.frame = NSRect(x: 60, y: (h - 26) / 2, width: w - 80, height: 26)
        bg.addSubview(mic)
        bg.addSubview(l)
        panel.contentView = bg
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2 + vf.height * 0.18, width: w, height: h), display: true)
        panel.orderFrontRegardless()
        label = l
    }
}
