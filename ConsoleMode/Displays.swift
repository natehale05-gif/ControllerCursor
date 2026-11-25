import AppKit
import SwiftUI

/// The connected displays and where they sit, in global (top-left origin) points
final class DisplayArrangement: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        var frame: CGRect
        let isMain: Bool
        let isBuiltIn: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published var message: String?
    private var observer: Any?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = Dictionary(NSScreen.screens.map { ($0.displayID, $0.localizedName) }, uniquingKeysWith: { a, _ in a })
        items = ids.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map { id in
            Item(id: id, name: names[id] ?? "Display", frame: CGDisplayBounds(id),
                 isMain: CGDisplayIsMain(id) != 0, isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// Where a display dropped at `origin` should go: touching the closest neighbour, never overlapping
    func snapped(_ id: CGDirectDisplayID, origin: CGPoint) -> CGPoint {
        guard let moving = items.first(where: { $0.id == id }) else { return origin }
        let size = moving.frame.size
        let others = items.filter { $0.id != id }.map(\.frame)
        guard !others.isEmpty else { return moving.frame.origin }
        var candidates: [CGPoint] = []
        for o in others {
            func clampY(_ y: CGFloat) -> CGFloat { min(max(y, o.minY - size.height + 40), o.maxY - 40) }
            func clampX(_ x: CGFloat) -> CGFloat { min(max(x, o.minX - size.width + 40), o.maxX - 40) }
            // Line up tops, centres or bottoms when close
            func alignY(_ y: CGFloat) -> CGFloat {
                let options = [o.minY, o.midY - size.height / 2, o.maxY - size.height]
                return options.first { abs($0 - y) < 60 } ?? clampY(y)
            }
            func alignX(_ x: CGFloat) -> CGFloat {
                let options = [o.minX, o.midX - size.width / 2, o.maxX - size.width]
                return options.first { abs($0 - x) < 60 } ?? clampX(x)
            }
            candidates.append(CGPoint(x: o.maxX, y: alignY(origin.y)))                 // right of it
            candidates.append(CGPoint(x: o.minX - size.width, y: alignY(origin.y)))   // left of it
            candidates.append(CGPoint(x: alignX(origin.x), y: o.maxY))                 // below it
            candidates.append(CGPoint(x: alignX(origin.x), y: o.minY - size.height))  // above it
        }
        let free = candidates.filter { c in
            let r = CGRect(origin: c, size: size).insetBy(dx: 1, dy: 1)
            return !others.contains { $0.intersects(r) }
        }
        return (free.isEmpty ? candidates : free).min {
            hypot($0.x - origin.x, $0.y - origin.y) < hypot($1.x - origin.x, $1.y - origin.y)
        } ?? origin
    }

    /// Saves the new spot with macOS (the same setting as System Settings → Displays → Arrange)
    func move(_ id: CGDirectDisplayID, to origin: CGPoint) {
        var frames = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.frame) })
        frames[id]?.origin = origin
        // The main display (the one with the menu bar) always sits at 0,0
        guard let main = items.first(where: \.isMain), let mainOrigin = frames[main.id]?.origin else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for (did, f) in frames {
            CGConfigureDisplayOrigin(config, did, Int32((f.minX - mainOrigin.x).rounded()), Int32((f.minY - mainOrigin.y).rounded()))
        }
        if CGCompleteDisplayConfiguration(config, .permanently) != .success {
            CGCancelDisplayConfiguration(config)
            message = "macOS didn't accept that arrangement"
        } else {
            message = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reload() }
    }

    /// Big numbers on each display so you can tell which is which
    func identify() {
        let ordered = items.sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        for (i, item) in ordered.enumerated() {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == item.id }) else { continue }
            let size = NSSize(width: 360, height: 220)
            let p = NSPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = NSHostingView(rootView: VStack(spacing: 6) {
                Text("\(i + 1)").font(.system(size: 110, weight: .bold, design: .rounded))
                Text(item.name).font(.title2.weight(.semibold))
            }.foregroundStyle(.white).frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 32).fill(.black.opacity(0.7))))
            p.contentView = v
            p.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { p.orderOut(nil) }
        }
    }

    func number(of id: CGDirectDisplayID) -> Int {
        let ordered = items.sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        return (ordered.firstIndex { $0.id == id } ?? 0) + 1
    }
}

struct DisplaysPane: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var arrangement = DisplayArrangement()
    @State private var dragging: CGDirectDisplayID?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        Form {
            Section {
                if arrangement.items.count < 2 {
                    VStack(spacing: 8) {
                        Image(systemName: "display.2").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Connect another display to arrange it here.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    canvas.frame(height: 300)
                }
                if let m = arrangement.message { Text(m).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Identify Displays") { arrangement.identify() }
                    Spacer()
                    Button("Open Apple's Display Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Arrangement")
            } footer: {
                Text("Drag a display to where it sits on your desk. It snaps against its neighbour, and macOS remembers it. The white bar marks the display with the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Moving Between Displays") {
                Toggle("Cross anywhere along a shared side", isOn: $settings.data.crossAnyEdge)
                Text("Push the pointer off a side of one display and it lands on the display next to it, even where their edges don't line up. Works with the controller, mouse and trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Quick Menu (hold L2) + L3 jumps straight to the next display. L2 + L1 / R1 switches desktops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { arrangement.reload() }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let items = arrangement.items
            let bounds = items.map(\.frame).reduce(items.first?.frame ?? .zero) { $0.union($1) }
            let pad: CGFloat = 24
            let scale = min((geo.size.width - pad * 2) / max(bounds.width, 1),
                            (geo.size.height - pad * 2) / max(bounds.height, 1)) * 0.8
            let offset = CGPoint(x: (geo.size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                 y: (geo.size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.15))
                ForEach(items) { item in
                    let isDragging = dragging == item.id
                    let r = item.frame
                    tile(item, size: CGSize(width: r.width * scale, height: r.height * scale), lifted: isDragging)
                        .offset(x: offset.x + r.minX * scale + (isDragging ? dragOffset.width : 0),
                                y: offset.y + r.minY * scale + (isDragging ? dragOffset.height : 0))
                        .zIndex(isDragging ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { v in dragging = item.id; dragOffset = v.translation }
                            .onEnded { v in
                                let proposed = CGPoint(x: r.minX + v.translation.width / scale,
                                                       y: r.minY + v.translation.height / scale)
                                let spot = arrangement.snapped(item.id, origin: proposed)
                                dragging = nil
                                dragOffset = .zero
                                if spot != r.origin { arrangement.move(item.id, to: spot) }
                            })
                }
            }
        }
    }

    private func tile(_ item: DisplayArrangement.Item, size: CGSize, lifted: Bool) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.42, blue: 0.85), Color(red: 0.08, green: 0.22, blue: 0.55)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(lifted ? 0.9 : 0.35), lineWidth: lifted ? 3 : 1.5)
            if item.isMain {
                Rectangle().fill(.white.opacity(0.85)).frame(height: max(4, size.height * 0.06))
            }
            VStack(spacing: 2) {
                Text("\(arrangement.number(of: item.id))").font(.system(size: min(36, size.height * 0.3), weight: .bold, design: .rounded))
                Text(item.name).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.6)
                Text("\(Int(item.frame.width)) × \(Int(item.frame.height))").font(.caption2).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(6)
            .frame(maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: lifted ? 8 : 0)
    }
}
