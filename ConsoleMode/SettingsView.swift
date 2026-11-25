import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsActions {
    var openAccessibility: () -> Void
    var quitControllerKeys: () -> Void
    var testRumble: () -> Void
}

enum Pane: String, CaseIterable, Identifiable {
    case general, controller, test, profiles, buttons, pointer, displays, display, games
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .controller: return "Controller"
        case .test: return "Test Controller"
        case .profiles: return "Profiles"
        case .buttons: return "Buttons"
        case .pointer: return "Pointer & Scrolling"
        case .displays: return "Displays"
        case .display: return "Display & Keyboard"
        case .games: return "Games"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .controller: return "gamecontroller"
        case .test: return "dot.radiowaves.left.and.right"
        case .profiles: return "person.2.crop.square.stack"
        case .buttons: return "circle.grid.cross"
        case .pointer: return "cursorarrow.motionlines"
        case .displays: return "display.2"
        case .display: return "textformat.size"
        case .games: return "flag.checkered"
        }
    }
    var tint: Color {
        switch self {
        case .general: return .gray
        case .controller: return .blue
        case .test: return .green
        case .profiles: return .purple
        case .buttons: return .indigo
        case .pointer: return .orange
        case .displays: return .cyan
        case .display: return .teal
        case .games: return .red
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var status: StatusModel
    let live: LiveInput   // only the Test Controller page watches it
    @ObservedObject var updater: Updater
    let actions: SettingsActions
    @State private var pane: Pane? = .general

    /// Bigger text and controls while you're using the controller
    private var large: Bool { status.controllerMode && settings.data.largeSettingsWithController }

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
                case .general: GeneralPane(settings: settings, status: status, updater: updater, actions: actions)
                case .test: TestControllerPane(live: live, status: status, style: settings.activeProfile.style)
                case .games: GamesPane(settings: settings, status: status)
                case .controller: ControllerPane(settings: settings, status: status, actions: actions)
                case .profiles: ProfilesPane(settings: settings)
                case .buttons: ButtonsPane(settings: settings)
                case .pointer: PointerPane(settings: settings)
                case .displays: DisplaysPane(settings: settings)
                case .display: DisplayPane(settings: settings)
                }
            }
            .navigationTitle((pane ?? .general).title)
        }
        .controlSize(large ? .large : .regular)
        .font(large ? .title3 : .body)
        .frame(minWidth: 760, minHeight: 500)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: StatusModel
    @ObservedObject var updater: Updater
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

            Section("Features") {
                Toggle("Media controls for video", isOn: $settings.data.mediaMode)
                Text("In the TV app, VLC, IINA, or a browser playing YouTube, Netflix, Disney+, Prime Video and the like, buttons switch to the Media profile: ✕ play/pause, D-pad seek and volume, □ captions, △ full screen. Change them in Buttons → Media.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep the Mac awake while using the controller", isOn: $settings.data.keepAwake)
                Text("Stops the screen dimming mid-video, and wakes a dimmed or sleeping display when you pick up the controller.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Sync settings with iCloud Drive", isOn: SwiftUI.Binding(
                    get: { settings.data.iCloudSync },
                    set: { on in if on { settings.enableCloudSync() } else { settings.data.iCloudSync = false } }))
                    .disabled(!AppSettings.iCloudAvailable && !settings.data.iCloudSync)
                Text(AppSettings.iCloudAvailable
                     ? "Shares buttons, profiles and settings with your other Macs through iCloud Drive → Console Mode."
                     : "Turn on iCloud Drive in System Settings → your name → iCloud to sync settings between Macs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Console Mode \(updater.current)")
                        if !updater.status.isEmpty {
                            Text(updater.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if updater.busy { ProgressView().controlSize(.small) }
                    Button("Check Now") { updater.check(install: true) }.disabled(updater.busy)
                }
                Toggle("Install updates automatically", isOn: $settings.data.autoUpdate)
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
                Picker("Mode", selection: $settings.data.lightMode) {
                    ForEach(LightMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch settings.data.lightMode {
                case .party:
                    Text("Slowly cycles through every color.").font(.caption).foregroundStyle(.secondary)
                case .battery:
                    Text("Green when charged, yellow around half, red when low. Pulses while charging.")
                        .font(.caption).foregroundStyle(.secondary)
                case .solid:
                    EmptyView()
                }
                if settings.data.lightMode == .solid {
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
            }

            Section("Gyro Aiming") {
                Picker("Gyro", selection: $settings.data.gyroMode) {
                    ForEach(GyroMode.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.data.gyroMode == .afterStick
                     ? "Push the stick near what you want, then tilt the controller slightly to land exactly on it."
                     : settings.data.gyroMode == .always ? "Tilting the controller always moves the pointer." : "The motion sensors are off.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.data.gyroMode != .off {
                    LabeledSlider(title: "Speed", value: $settings.data.gyroSpeed, low: "Slow", high: "Fast")
                    Toggle("Reverse left and right", isOn: $settings.data.gyroInvertX)
                    Toggle("Reverse up and down", isOn: $settings.data.gyroInvertY)
                }
            }

            Section("Adaptive Triggers") {
                Toggle("Trigger feel", isOn: $settings.data.adaptiveTriggers)
                Text("R2 clicks like a button when it presses Return, and L2 pushes back gently while the Quick Menu is held. DualSense only; games use their own.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Rumble when you click", isOn: $settings.data.rumble)
                Toggle("Rumble ticks while scrolling", isOn: $settings.data.scrollTicks)
                    .disabled(!settings.data.rumble)
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
    private var style: ControllerStyle { settings.activeProfile.style }

    var body: some View {
        Form {
            Section {
                Picker("Profile", selection: $settings.data.activeProfileID) {
                    ForEach(settings.data.profiles) { p in Text(p.name).tag(p.id) }
                }
                Picker("Layer", selection: $quickMenu) {
                    Text("Standard").tag(false)
                    Text("\(style.quickMenuName) Quick Menu").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(quickMenu
                     ? "These run while you hold \(style.quickMenuName). Buttons set to Nothing keep their Standard action."
                     : "Press runs when you tap a button. Hold runs when you hold it for half a second.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if quickMenu {
                Section {
                    ForEach(0..<8, id: \.self) { i in
                        Picker(Self.wheelNames[i], selection: wheelBinding(i)) {
                            ForEach(ActionKind.groups, id: \.0) { group in
                                Section(group.0) {
                                    ForEach(group.1.filter { $0 != .voiceTyping }) { k in Text(k.title).tag(k) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Quick Menu Wheel")
                } footer: {
                    HStack {
                        Text("Hold \(style.quickMenuName), point the right stick at a slice, then let go of \(style.quickMenuName).")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Wheel") { settings.data.wheel = Defaults.wheel }
                    }
                }
            }

            Section {
                ForEach(buttons) { b in
                    ButtonRow(button: b, style: style, binding: bindingFor(b), showHold: !quickMenu)
                }
            } footer: {
                HStack {
                    Text("\(style.quickMenuName) opens the Quick Menu while held. While the keyboard is open: D-pad moves between keys and ✕ types, □ delete, R3 space, L1/R1 move, L2 shift, R2 return, △ or ○ close.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore \(style.title) Layout") { settings.resetButtons() }
                }
            }
        }
        .formStyle(.grouped)
    }

    static let wheelNames = ["Top", "Top Right", "Right", "Bottom Right", "Bottom", "Bottom Left", "Left", "Top Left"]

    private func wheelBinding(_ i: Int) -> SwiftUI.Binding<ActionKind> {
        SwiftUI.Binding(get: { settings.data.wheel[i] }, set: { settings.data.wheel[i] = $0 })
    }

    private func bindingFor(_ b: PadButton) -> SwiftUI.Binding<ButtonBinding> {
        let q = quickMenu
        return SwiftUI.Binding(
            get: { settings.editingBinding(for: b, quickMenu: q) },
            set: { nv in settings.setBinding(nv, for: b, quickMenu: q) })
    }
}

struct ButtonRow: View {
    let button: PadButton
    let style: ControllerStyle
    @SwiftUI.Binding var binding: ButtonBinding
    let showHold: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(button.name(for: style)).frame(width: 170, alignment: .leading)
                ActionPicker(title: "Press", action: $binding.press)
                if showHold {
                    ActionPicker(title: "Hold", action: $binding.hold)
                }
            }
            if binding.press.kind == .shortcut { ShortcutEditor(action: $binding.press) }
            if showHold && binding.hold.kind == .shortcut { ShortcutEditor(action: $binding.hold) }
            if binding.press.kind == .runShortcut { ShortcutsAppPicker(action: $binding.press) }
            if showHold && binding.hold.kind == .runShortcut { ShortcutsAppPicker(action: $binding.hold) }
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

/// Picks a shortcut from Apple's Shortcuts app
struct ShortcutsAppPicker: View {
    @SwiftUI.Binding var action: Action
    @State private var names: [String] = []
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 170)
            Picker("Shortcut", selection: SwiftUI.Binding(get: { action.name ?? "" }, set: { action.name = $0 })) {
                Text("Choose…").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
                if let n = action.name, !n.isEmpty, !names.contains(n) { Text(n).tag(n) }
            }
            .frame(maxWidth: 320)
            if !loaded { ProgressView().controlSize(.small) }
            else if names.isEmpty { Text("No shortcuts found in the Shortcuts app").font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .onAppear {
            SystemControls.shortcutNames { names = $0; loaded = true }
        }
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
                Toggle("Two-finger gestures", isOn: $settings.data.touchpadGestures)
                Text("Slide two fingers to scroll. Flick two fingers left or right to change desktops, up for Mission Control, down for the app's windows.")
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
                Text("Everything gets bigger while you use the controller, and goes back to normal a few seconds after you use the mouse or trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Button Hints") {
                Picker("On-screen hints", selection: $settings.data.hintsMode) {
                    ForEach(HintsMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Shows what ✕ ○ □ △ do along the bottom of the screen, like a console. Changes while you hold L2 or use the keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Settings Window") {
                Toggle("Bigger text in Settings while using the controller", isOn: $settings.data.largeSettingsWithController)
            }
            Section("On-Screen Keyboard") {
                Toggle("Swipe typing with the touchpad", isOn: $settings.data.swipeTyping)
                Picker("Key Size", selection: $settings.data.keyboardKeySize) {
                    Text("Small").tag(52.0)
                    Text("Medium").tag(64.0)
                    Text("Large").tag(76.0)
                    Text("Extra Large").tag(90.0)
                }
                Text("The keyboard stays this size whatever the screen size is. Move between keys with the D-pad and press ✕, or aim with the circle. Swipe a finger across the touchpad to type whole words (R1 picks the next guess). □ delete, R3 space, L1/R1 move, L2 shift, R2 return, L3 voice, △ or ○ close. Hold △ anywhere to talk instead of typing, and hold Options for Siri.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: - Profiles

struct ProfilesPane: View {
    @ObservedObject var settings: AppSettings
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ForEach(settings.data.profiles) { p in
                    HStack(spacing: 12) {
                        Image(systemName: p.style == .xbox ? "xbox.logo" : "playstation.logo")
                            .font(.title3)
                            .frame(width: 26)
                            .foregroundStyle(p.id == settings.data.activeProfileID ? Color.accentColor : .secondary)
                        if renaming == p.id {
                            TextField("Name", text: $newName, onCommit: { commitRename(p.id) })
                                .textFieldStyle(.roundedBorder)
                            Button("Done") { commitRename(p.id) }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(p.apps.isEmpty ? "\(p.style.title) layout"
                                     : "\(p.style.title) layout · used in \(p.apps.map(appName).joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.id == settings.data.activeProfileID {
                                Text("In Use").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            } else {
                                Button("Use") { settings.data.activeProfileID = p.id }
                            }
                            Menu {
                                Button("Rename…") { newName = p.name; renaming = p.id }
                                Button("Export…") { export(p) }
                                Button("Use for an App…") { assignApp(p.id) }
                                if !p.apps.isEmpty {
                                    Menu("Stop Using for App") {
                                        ForEach(p.apps, id: \.self) { id in
                                            Button(appName(id)) { removeApp(id, from: p.id) }
                                        }
                                    }
                                }
                                Picker("Controller Type", selection: styleBinding(p.id)) {
                                    ForEach(ControllerStyle.allCases) { Text($0.title).tag($0) }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { settings.deleteProfile(p.id) }
                                    .disabled(settings.data.profiles.count <= 1)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 28)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Button Profiles")
            } footer: {
                HStack {
                    Button("Duplicate Current") { settings.duplicateActive() }
                    Button("Import…") { importProfiles() }
                    Spacer()
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }

            Section {
                Toggle("Switch profiles to match the controller", isOn: $settings.data.autoSwitchProfile)
                Text("Connect an Xbox controller and the Xbox profile is used; connect a DualSense and the PlayStation profile is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func assignApp(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.message = "Choose apps that should use this profile while they're in front"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        for i in settings.data.profiles.indices {
            settings.data.profiles[i].apps.removeAll { ids.contains($0) }   // one profile per app
            if settings.data.profiles[i].id == id { settings.data.profiles[i].apps += ids }
        }
        message = ids.isEmpty ? nil : "Assigned \(ids.count) app\(ids.count == 1 ? "" : "s")."
    }

    private func removeApp(_ bundleID: String, from id: UUID) {
        if let i = settings.data.profiles.firstIndex(where: { $0.id == id }) {
            settings.data.profiles[i].apps.removeAll { $0 == bundleID }
        }
    }

    private func styleBinding(_ id: UUID) -> SwiftUI.Binding<ControllerStyle> {
        SwiftUI.Binding(
            get: { settings.data.profiles.first { $0.id == id }?.style ?? .playstation },
            set: { v in
                if let i = settings.data.profiles.firstIndex(where: { $0.id == id }) { settings.data.profiles[i].style = v }
            })
    }

    private func commitRename(_ id: UUID) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let i = settings.data.profiles.firstIndex(where: { $0.id == id }) {
            settings.data.profiles[i].name = name
        }
        renaming = nil
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose one or more Console Mode profiles"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let n = settings.importProfiles(from: panel.urls)
        message = n == 0 ? "Those files aren't Console Mode profiles." : "Imported \(n) profile\(n == 1 ? "" : "s")."
    }

    private func export(_ p: Profile) {
        guard let data = settings.exportData(for: p.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = p.name + ".json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
        message = "Exported \(p.name)."
    }
}


// MARK: - Games

struct GamesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: StatusModel

    var body: some View {
        Form {
            Section {
                Toggle("Step aside while a game is open", isOn: $settings.data.pauseInGames)
                Text("Games read the controller directly, the way Apple designed it. While one is in front, Console Mode stops remapping buttons, hides the circle and puts the screen back to normal size. The PS button opens Apple's game overlay.")
                    .font(.caption).foregroundStyle(.secondary)
                if let game = status.pausedForGame {
                    Label("Paused right now for \(game)", systemImage: "pause.circle.fill").foregroundStyle(.green)
                }
            }
            Section {
                Text("Detected automatically: App Store games, Steam games, Apple Games, Steam, GeForce NOW, Epic, Battle.net, CrossOver, Whisky and common emulators.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(settings.data.extraGames, id: \.self) { id in
                    HStack {
                        Text(name(id))
                        Spacer()
                        Button(role: .destructive) { settings.data.extraGames.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add a Game…") { addGames() }
            } header: {
                Text("Games")
            }
        }
        .formStyle(.grouped)
    }

    private func name(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    private func addGames() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose games that Console Mode should step aside for"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.data.extraGames.contains(id) {
                settings.data.extraGames.append(id)
            }
        }
    }
}

// MARK: - Test Controller

struct TestControllerPane: View {
    @ObservedObject var live: LiveInput
    @ObservedObject var status: StatusModel
    let style: ControllerStyle

    var body: some View {
        Form {
            Section {
                HStack {
                    statusDot(status.connected)
                    Text(status.connected ? status.controllerName : "No controller connected")
                    Spacer()
                    if let b = status.battery { Text("Battery \(Int(b * 100))%").foregroundStyle(.secondary) }
                }
                ControllerDiagram(live: live, style: style)
                    .frame(height: 330)
                Text("Press buttons, move the sticks and touch the touchpad. Anything that lights up here is reaching Console Mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ControllerDiagram: View {
    @ObservedObject var live: LiveInput
    let style: ControllerStyle

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let cx = w / 2
            let accent = Color.accentColor
            func on(_ b: PadButton) -> Bool { live.pressed.contains(b) }
            func circle(_ c: CGPoint, _ r: CGFloat, _ lit: Bool, _ label: String) {
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(lit ? accent : Color.secondary.opacity(0.18)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                ctx.draw(Text(label).font(.system(size: r * 0.9, weight: .bold)).foregroundColor(lit ? .white : .primary), at: c)
            }
            func pill(_ rect: CGRect, _ lit: Bool, _ label: String, fill: Double = 0) {
                let path = Path(roundedRect: rect, cornerRadius: rect.height / 2)
                ctx.fill(path, with: .color(Color.secondary.opacity(0.18)))
                if fill > 0 {
                    var c = ctx
                    c.clip(to: path)
                    c.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * fill, height: rect.height)), with: .color(accent.opacity(0.6)))
                }
                if lit { ctx.fill(path, with: .color(accent)) }
                ctx.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                ctx.draw(Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(lit ? .white : .primary),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            }
            let xbox = style == .xbox
            // Shoulders and triggers
            pill(CGRect(x: cx - 250, y: 10, width: 110, height: 26), on(.l2), xbox ? "LT" : "L2", fill: Double(live.l2))
            pill(CGRect(x: cx + 140, y: 10, width: 110, height: 26), on(.r2), xbox ? "RT" : "R2", fill: Double(live.r2))
            pill(CGRect(x: cx - 250, y: 44, width: 110, height: 26), on(.l1), xbox ? "LB" : "L1")
            pill(CGRect(x: cx + 140, y: 44, width: 110, height: 26), on(.r1), xbox ? "RB" : "R1")
            // Touchpad
            let tp = CGRect(x: cx - 95, y: 40, width: 190, height: 90)
            let tpPath = Path(roundedRect: tp, cornerRadius: 12)
            ctx.fill(tpPath, with: .color(on(.touchpad) ? accent.opacity(0.5) : Color.secondary.opacity(0.12)))
            ctx.stroke(tpPath, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
            for t in live.touches {
                let p = CGPoint(x: tp.midX + t.x * tp.width / 2, y: tp.midY - t.y * tp.height / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(accent))
            }
            if !xbox { ctx.draw(Text("Touchpad").font(.caption).foregroundColor(.secondary), at: CGPoint(x: tp.midX, y: tp.maxY - 12)) }
            // Small centre buttons
            pill(CGRect(x: cx - 165, y: 92, width: 60, height: 22), on(.create), xbox ? "View" : "Create")
            pill(CGRect(x: cx + 105, y: 92, width: 60, height: 22), on(.options), xbox ? "Menu" : "Options")
            circle(CGPoint(x: cx, y: 160), 16, on(.ps), xbox ? "⊗" : "PS")
            // D-pad
            let dp = CGPoint(x: cx - 200, y: 170)
            circle(CGPoint(x: dp.x, y: dp.y - 34), 17, on(.up), "↑")
            circle(CGPoint(x: dp.x, y: dp.y + 34), 17, on(.down), "↓")
            circle(CGPoint(x: dp.x - 34, y: dp.y), 17, on(.left), "←")
            circle(CGPoint(x: dp.x + 34, y: dp.y), 17, on(.right), "→")
            // Face buttons
            let fb = CGPoint(x: cx + 200, y: 170)
            circle(CGPoint(x: fb.x, y: fb.y - 34), 19, on(.triangle), xbox ? "Y" : "△")
            circle(CGPoint(x: fb.x, y: fb.y + 34), 19, on(.cross), xbox ? "A" : "✕")
            circle(CGPoint(x: fb.x - 34, y: fb.y), 19, on(.square), xbox ? "X" : "□")
            circle(CGPoint(x: fb.x + 34, y: fb.y), 19, on(.circle), xbox ? "B" : "○")
            // Sticks
            for (c, v, b, name) in [(CGPoint(x: cx - 90, y: h - 70), live.left, PadButton.l3, xbox ? "LS" : "L3"),
                                    (CGPoint(x: cx + 90, y: h - 70), live.right, PadButton.r3, xbox ? "RS" : "R3")] {
                let r: CGFloat = 46
                let base = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: base), with: .color(Color.secondary.opacity(on(b) ? 0.4 : 0.12)))
                ctx.stroke(Path(ellipseIn: base), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                let knob = CGPoint(x: c.x + v.x * (r - 16), y: c.y - v.y * (r - 16))
                ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 16, y: knob.y - 16, width: 32, height: 32)),
                         with: .color(on(b) ? accent : Color.primary.opacity(0.7)))
                ctx.draw(Text(name).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: c.x, y: c.y + r + 10))
            }
        }
    }
}
