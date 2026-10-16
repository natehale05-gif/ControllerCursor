import SwiftUI
import ServiceManagement

struct SettingsActions {
    var openAccessibility: () -> Void
    var quitControllerKeys: () -> Void
    var testRumble: () -> Void
}

enum Pane: String, CaseIterable, Identifiable {
    case general, controller, buttons, pointer, display
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .controller: return "Controller"
        case .buttons: return "Buttons"
        case .pointer: return "Pointer & Scrolling"
        case .display: return "Display & Keyboard"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .controller: return "gamecontroller"
        case .buttons: return "circle.grid.cross"
        case .pointer: return "cursorarrow.motionlines"
        case .display: return "textformat.size"
        }
    }
    var tint: Color {
        switch self {
        case .general: return .gray
        case .controller: return .blue
        case .buttons: return .indigo
        case .pointer: return .orange
        case .display: return .teal
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var status: StatusModel
    let actions: SettingsActions
    @State private var pane: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label {
                        Text(p.title)
                    } icon: {
                        Image(systemName: p.icon)
                            .foregroundStyle(.white)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(p.tint.gradient))
                    }
                    .tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane(settings: settings, status: status, actions: actions)
                case .controller: ControllerPane(settings: settings, status: status, actions: actions)
                case .buttons: ButtonsPane(settings: settings)
                case .pointer: PointerPane(settings: settings)
                case .display: DisplayPane(settings: settings)
                }
            }
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 760, minHeight: 500)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: StatusModel
    let actions: SettingsActions
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Use controller to control your Mac", isOn: $settings.data.enabled)
                Toggle("Open at Login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Permissions") {
                HStack {
                    statusDot(status.hasAccessibility)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text("Lets your controller move the pointer, click and type.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !status.hasAccessibility {
                        Button("Open Settings…", action: actions.openAccessibility)
                    } else {
                        Text("Allowed").foregroundStyle(.secondary)
                    }
                }
            }

            if status.controllerKeysRunning {
                Section("ControllerKeys") {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ControllerKeys is still running")
                            Text("Both apps will react to every button. Quit it, and turn off its Open at Login.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Quit ControllerKeys", action: actions.quitControllerKeys)
                    }
                }
            }

            Section("How it works") {
                Text("Use the controller and the screen gets bigger, with a circle around the pointer. Touch your mouse or trackpad and it goes back to normal. Hold L2 for the Quick Menu, and press △ for the keyboard.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

func statusDot(_ ok: Bool) -> some View {
    Circle().fill(ok ? Color.green : Color.orange).frame(width: 9, height: 9)
}

// MARK: - Controller

struct ControllerPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: StatusModel
    let actions: SettingsActions

    private var lightColor: SwiftUI.Binding<Color> {
        SwiftUI.Binding(
            get: { Color(red: settings.data.lightRed, green: settings.data.lightGreen, blue: settings.data.lightBlue) },
            set: { c in
                let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? .systemBlue
                settings.data.lightRed = Double(ns.redComponent)
                settings.data.lightGreen = Double(ns.greenComponent)
                settings.data.lightBlue = Double(ns.blueComponent)
            })
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(status.connected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.controllerName).font(.headline)
                        Text(status.connected ? "Connected" : "Turn on your controller or connect it in Bluetooth settings")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let b = status.battery {
                        HStack(spacing: 6) {
                            Image(systemName: status.charging ? "battery.100.bolt" : batteryIcon(b))
                            Text("\(Int(b * 100))%").monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Light Bar") {
                ColorPicker("Color", selection: lightColor, supportsOpacity: false)
                HStack {
                    ForEach([("Blue", Color(red: 0, green: 0.35, blue: 1)), ("White", .white),
                             ("Purple", Color(red: 0.55, green: 0.2, blue: 1)), ("Red", .red),
                             ("Green", .green)], id: \.0) { item in
                        Button { lightColor.wrappedValue = item.1 } label: {
                            Circle().fill(item.1).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.secondary.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                        .help(item.0)
                    }
                }
            }

            Section("Feedback") {
                Toggle("Rumble when you click", isOn: $settings.data.rumble)
                Button("Test Rumble", action: actions.testRumble)
            }
        }
        .formStyle(.grouped)
    }

    private func batteryIcon(_ b: Float) -> String {
        switch b {
        case ..<0.15: return "battery.0"
        case ..<0.4: return "battery.25"
        case ..<0.65: return "battery.50"
        case ..<0.9: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Buttons

struct ButtonsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var quickMenu = false

    private var buttons: [PadButton] { PadButton.allCases.filter { $0 != .l2 } }

    var body: some View {
        Form {
            Section {
                Picker("Layer", selection: $quickMenu) {
                    Text("Standard").tag(false)
                    Text("L2 Quick Menu").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(quickMenu
                     ? "These run while you hold L2. Buttons set to Nothing keep their Standard action."
                     : "Press runs when you tap a button. Hold runs when you hold it for half a second.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(buttons) { b in
                    ButtonRow(button: b, binding: bindingFor(b), showHold: !quickMenu)
                }
            } footer: {
                HStack {
                    Text("L2 opens the Quick Menu while held. While the keyboard is open: □ delete, △ space, L1/R1 move, L2 shift, R2 return, ○ close.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore PS5 Layout") { settings.resetButtons() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bindingFor(_ b: PadButton) -> SwiftUI.Binding<ButtonBinding> {
        let q = quickMenu
        return SwiftUI.Binding(
            get: { settings.binding(for: b, quickMenu: q) },
            set: { nv in
                if q { settings.data.quickMenu[b] = nv } else { settings.data.base[b] = nv }
            })
    }
}

struct ButtonRow: View {
    let button: PadButton
    @SwiftUI.Binding var binding: ButtonBinding
    let showHold: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(button.name).frame(width: 170, alignment: .leading)
                ActionPicker(title: "Press", action: $binding.press)
                if showHold {
                    ActionPicker(title: "Hold", action: $binding.hold)
                }
            }
            if binding.press.kind == .shortcut { ShortcutEditor(action: $binding.press) }
            if showHold && binding.hold.kind == .shortcut { ShortcutEditor(action: $binding.hold) }
        }
    }
}

struct ActionPicker: View {
    let title: String
    @SwiftUI.Binding var action: Action

    var body: some View {
        Picker(title, selection: SwiftUI.Binding(
            get: { action.kind },
            set: { k in
                action = Action(kind: k, custom: k == .shortcut ? (action.custom ?? KeyShortcut(keyCode: 0, command: true)) : nil)
            })) {
            Text("Nothing").tag(ActionKind.none)
            ForEach(ActionKind.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { k in Text(k.title).tag(k) }
                }
            }
            Divider()
            Text("Custom Shortcut…").tag(ActionKind.shortcut)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ShortcutEditor: View {
    @SwiftUI.Binding var action: Action

    private var shortcut: SwiftUI.Binding<KeyShortcut> {
        SwiftUI.Binding(get: { action.custom ?? KeyShortcut(keyCode: 0) }, set: { action.custom = $0 })
    }

    var body: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 170)
            Toggle("⌃", isOn: shortcut.control).toggleStyle(.button)
            Toggle("⌥", isOn: shortcut.option).toggleStyle(.button)
            Toggle("⇧", isOn: shortcut.shift).toggleStyle(.button)
            Toggle("⌘", isOn: shortcut.command).toggleStyle(.button)
            Picker("Key", selection: shortcut.keyCode) {
                ForEach(KeyNames.all, id: \.1) { k in Text(k.0).tag(k.1) }
            }
            .labelsHidden()
            .frame(width: 110)
            Text(KeyNames.describe(shortcut.wrappedValue)).foregroundStyle(.secondary).monospaced()
        }
        .font(.callout)
    }
}

// MARK: - Pointer

struct PointerPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Left Stick — Pointer") {
                LabeledSlider(title: "Speed", value: $settings.data.stickSpeed, low: "Slow", high: "Fast")
                LabeledSlider(title: "Precision", value: $settings.data.stickAcceleration, low: "Linear", high: "Precise")
                Text("Higher precision makes small pushes slower while a full push still moves fast.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Right Stick — Scrolling") {
                LabeledSlider(title: "Speed", value: $settings.data.scrollSpeed, low: "Slow", high: "Fast")
                Toggle("Reverse scroll direction", isOn: $settings.data.invertScroll)
            }
            Section("Touchpad") {
                LabeledSlider(title: "Speed", value: $settings.data.touchpadSpeed, low: "Slow", high: "Fast")
                Text("Tap or press to click. Press with two fingers for the options menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Circle") {
                Picker("Size", selection: $settings.data.circleSize) {
                    Text("Small").tag(32.0)
                    Text("Medium").tag(44.0)
                    Text("Large").tag(56.0)
                    Text("Extra Large").tag(72.0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LabeledSlider: View {
    let title: String
    @SwiftUI.Binding var value: Double
    let low: String
    let high: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(low).font(.caption).foregroundStyle(.secondary)
                Slider(value: $value, in: 0...1)
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Display & Keyboard

struct DisplayPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Bigger Screen With Controller") {
                Picker("Size", selection: $settings.data.screenScale) {
                    Text("Off").tag(1.0)
                    Text("Bigger").tag(0.85)
                    Text("Much Bigger").tag(0.72)
                    Text("Huge").tag(0.6)
                    Text("Extra Huge").tag(0.5)
                    Text("Largest Possible").tag(0.01)
                }
                Text("Everything gets bigger while you use the controller, and goes back to normal a few seconds after you use the mouse or trackpad. Takes effect the next time the controller takes over.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On-Screen Keyboard") {
                Picker("Key Size", selection: $settings.data.keyboardKeySize) {
                    Text("Small").tag(52.0)
                    Text("Medium").tag(64.0)
                    Text("Large").tag(76.0)
                    Text("Extra Large").tag(90.0)
                }
                Text("The keyboard stays this size whatever the screen size is. Aim with the pointer and press ✕, or use □ delete, △ space, L1/R1 move, L2 shift, R2 return, ○ close.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
