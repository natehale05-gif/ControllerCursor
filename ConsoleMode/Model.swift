import AppKit
import Combine

// MARK: - Controller buttons (PlayStation names)

enum PadButton: String, Codable, CaseIterable, Identifiable {
    case cross, circle, square, triangle
    case l1, r1, l2, r2
    case up, down, left, right
    case options, create, ps
    case l3, r3, touchpad

    var id: String { rawValue }

    var name: String {
        switch self {
        case .cross: return "✕ Cross"
        case .circle: return "○ Circle"
        case .square: return "□ Square"
        case .triangle: return "△ Triangle"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .up: return "D-pad Up"
        case .down: return "D-pad Down"
        case .left: return "D-pad Left"
        case .right: return "D-pad Right"
        case .options: return "Options"
        case .create: return "Create"
        case .ps: return "PS Button"
        case .l3: return "L3 (left stick click)"
        case .r3: return "R3 (right stick click)"
        case .touchpad: return "Touchpad Click"
        }
    }

    /// Name as printed on an Xbox controller
    var xboxName: String {
        switch self {
        case .cross: return "Ⓐ A"
        case .circle: return "Ⓑ B"
        case .square: return "Ⓧ X"
        case .triangle: return "Ⓨ Y"
        case .l1: return "LB"
        case .r1: return "RB"
        case .l2: return "LT"
        case .r2: return "RT"
        case .options: return "Menu ☰"
        case .create: return "View ⧉"
        case .ps: return "Xbox Button"
        case .l3: return "LS (left stick click)"
        case .r3: return "RS (right stick click)"
        case .touchpad: return "Share"
        default: return name
        }
    }

    func name(for style: ControllerStyle) -> String { style == .xbox ? xboxName : name }

    /// Short label for hints
    var glyph: String {
        switch self {
        case .cross: return "✕"
        case .circle: return "○"
        case .square: return "□"
        case .triangle: return "△"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .options: return "☰"
        case .touchpad: return "Touchpad"
        default: return name.components(separatedBy: " ").first ?? name
        }
    }
}

extension PadButton: CodingKeyRepresentable {}

enum ControllerStyle: String, Codable, CaseIterable, Identifiable {
    case playstation, xbox
    var id: String { rawValue }
    var title: String { self == .xbox ? "Xbox" : "PlayStation" }
    /// The button that opens the Quick Menu while held
    var quickMenuName: String { self == .xbox ? "LT" : "L2" }
}

/// A full button layout that can be switched, shared and imported
struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var style: ControllerStyle
    var base: [PadButton: ButtonBinding]
    var quickMenu: [PadButton: ButtonBinding]
    /// Apps (bundle IDs) that automatically use this profile while they're in front
    var apps: [String] = []

    init(id: UUID = UUID(), name: String, style: ControllerStyle,
         base: [PadButton: ButtonBinding], quickMenu: [PadButton: ButtonBinding], apps: [String] = []) {
        self.id = id; self.name = name; self.style = style; self.base = base; self.quickMenu = quickMenu
        self.apps = apps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Imported Profile"
        style = (try? c.decode(ControllerStyle.self, forKey: .style)) ?? .playstation
        base = (try? c.decode([PadButton: ButtonBinding].self, forKey: .base)) ?? Defaults.base
        quickMenu = (try? c.decode([PadButton: ButtonBinding].self, forKey: .quickMenu)) ?? Defaults.quickMenu
        apps = (try? c.decode([String].self, forKey: .apps)) ?? []
    }
}

enum HintsMode: String, Codable, CaseIterable, Identifiable {
    case autoHide, always, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .autoHide: return "Show when buttons are pressed"
        case .always: return "Always show"
        case .off: return "Off"
        }
    }
}

enum LightMode: String, Codable, CaseIterable, Identifiable {
    case solid, party, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: return "Solid Color"
        case .party: return "Party"
        case .battery: return "Battery Level"
        }
    }
}

// MARK: - Actions

struct KeyShortcut: Codable, Hashable {
    var keyCode: UInt16
    var command = false
    var option = false
    var control = false
    var shift = false

    var flags: CGEventFlags {
        var f: CGEventFlags = []
        if command { f.insert(.maskCommand) }
        if option { f.insert(.maskAlternate) }
        if control { f.insert(.maskControl) }
        if shift { f.insert(.maskShift) }
        return f
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    // Pointer
    case leftClick, rightClick, middleClick
    // Console
    case keyboard, spotlight, missionControl, appWindows, showDesktop, appSwitcher, lastApp
    case launchpad, finder
    // Keys
    case escape, enter, delete, tab, space
    case arrowUp, arrowDown, arrowLeft, arrowRight, pageUp, pageDown
    // Tabs & windows
    case nextTab, previousTab, newTab, reopenTab, closeWindow, quitApp, fullScreen, minimize
    case pageBack, pageForward, reload, find, zoomIn, zoomOut
    // Editing
    case copy, paste, cut, selectAll, undo, redo
    // Capture
    case screenshot, captureMenu
    // Media
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    // Navigation & typing
    case jumpUp, jumpDown, jumpLeft, jumpRight, voiceTyping, siri
    case previousDesktop, nextDesktop, previousDisplay, nextDisplay
    // Leave it to macOS (PS / Create buttons)
    case appleDefault
    // Custom
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .leftClick: return "Select (Click)"
        case .rightClick: return "Options Menu (Right Click)"
        case .middleClick: return "Middle Click"
        case .keyboard: return "On-Screen Keyboard"
        case .spotlight: return "Search (Spotlight)"
        case .missionControl: return "All Windows (Mission Control)"
        case .appWindows: return "App Windows"
        case .showDesktop: return "Home (Show Desktop)"
        case .appSwitcher: return "Switch Apps"
        case .lastApp: return "Last App"
        case .launchpad: return "Apps (Launchpad)"
        case .finder: return "Files (Finder)"
        case .escape: return "Back (Esc)"
        case .enter: return "Enter / Return"
        case .delete: return "Delete (Backspace)"
        case .tab: return "Tab"
        case .space: return "Space"
        case .arrowUp: return "Arrow Up"
        case .arrowDown: return "Arrow Down"
        case .arrowLeft: return "Arrow Left"
        case .arrowRight: return "Arrow Right"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .newTab: return "New Tab"
        case .reopenTab: return "Reopen Closed Tab"
        case .closeWindow: return "Close Window"
        case .quitApp: return "Quit App"
        case .fullScreen: return "Full Screen"
        case .minimize: return "Minimize Window"
        case .pageBack: return "Go Back"
        case .pageForward: return "Go Forward"
        case .reload: return "Reload"
        case .find: return "Find"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .cut: return "Cut"
        case .selectAll: return "Select All"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .screenshot: return "Screenshot"
        case .captureMenu: return "Screenshot & Record Menu"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .jumpUp: return "Jump Up (to buttons & links)"
        case .jumpDown: return "Jump Down (to buttons & links)"
        case .jumpLeft: return "Jump Left (to buttons & links)"
        case .jumpRight: return "Jump Right (to buttons & links)"
        case .voiceTyping: return "Voice Typing (hold to talk)"
        case .siri: return "Ask Siri"
        case .previousDesktop: return "Previous Desktop (Space on the left)"
        case .nextDesktop: return "Next Desktop (Space on the right)"
        case .previousDisplay: return "Previous Display (move pointer)"
        case .nextDisplay: return "Next Display (move pointer)"
        case .appleDefault: return "Apple Default"
        case .shortcut: return "Custom Shortcut…"
        }
    }

    /// Groups for the action picker
    static let groups: [(String, [ActionKind])] = [
        ("Pointer", [.leftClick, .rightClick, .middleClick, .jumpUp, .jumpDown, .jumpLeft, .jumpRight]),
        ("Console", [.keyboard, .voiceTyping, .siri, .appleDefault, .spotlight, .missionControl, .appWindows, .showDesktop, .appSwitcher,
                     .lastApp, .launchpad, .finder]),
        ("Displays & Desktops", [.nextDisplay, .previousDisplay, .nextDesktop, .previousDesktop]),
        ("Keys", [.escape, .enter, .delete, .tab, .space, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
                  .pageUp, .pageDown]),
        ("Tabs & Windows", [.nextTab, .previousTab, .newTab, .reopenTab, .closeWindow, .quitApp, .fullScreen,
                            .minimize, .pageBack, .pageForward, .reload, .find, .zoomIn, .zoomOut]),
        ("Editing", [.copy, .paste, .cut, .selectAll, .undo, .redo]),
        ("Capture", [.screenshot, .captureMenu]),
        ("Media", [.playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute,
                   .brightnessUp, .brightnessDown]),
    ]

    /// The key combo behind keyboard-style actions
    var shortcut: KeyShortcut? {
        func k(_ code: UInt16, cmd: Bool = false, opt: Bool = false, ctrl: Bool = false, shift: Bool = false) -> KeyShortcut {
            KeyShortcut(keyCode: code, command: cmd, option: opt, control: ctrl, shift: shift)
        }
        switch self {
        case .spotlight: return k(49, cmd: true)
        case .missionControl: return k(126, ctrl: true)
        case .previousDesktop: return k(123, ctrl: true)
        case .nextDesktop: return k(124, ctrl: true)
        case .appWindows: return k(125, ctrl: true)
        case .showDesktop: return k(103)            // F11
        case .appSwitcher, .lastApp: return k(48, cmd: true)
        case .escape: return k(53)
        case .enter: return k(36)
        case .delete: return k(51)
        case .tab: return k(48)
        case .space: return k(49)
        case .arrowUp: return k(126)
        case .arrowDown: return k(125)
        case .arrowLeft: return k(123)
        case .arrowRight: return k(124)
        case .pageUp: return k(116)
        case .pageDown: return k(121)
        case .nextTab: return k(48, ctrl: true)
        case .previousTab: return k(48, ctrl: true, shift: true)
        case .newTab: return k(17, cmd: true)
        case .reopenTab: return k(17, cmd: true, shift: true)
        case .closeWindow: return k(13, cmd: true)
        case .quitApp: return k(12, cmd: true)
        case .fullScreen: return k(3, cmd: true, ctrl: true)
        case .minimize: return k(46, cmd: true)
        case .pageBack: return k(33, cmd: true)
        case .pageForward: return k(30, cmd: true)
        case .reload: return k(15, cmd: true)
        case .find: return k(3, cmd: true)
        case .zoomIn: return k(24, cmd: true)
        case .zoomOut: return k(27, cmd: true)
        case .copy: return k(8, cmd: true)
        case .paste: return k(9, cmd: true)
        case .cut: return k(7, cmd: true)
        case .selectAll: return k(0, cmd: true)
        case .undo: return k(6, cmd: true)
        case .redo: return k(6, cmd: true, shift: true)
        case .screenshot: return k(20, cmd: true, shift: true)
        case .captureMenu: return k(23, cmd: true, shift: true)
        default: return nil
        }
    }

    /// Held keys that should repeat like a real keyboard
    var repeats: Bool {
        [.delete, .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .pageUp, .pageDown,
         .volumeUp, .volumeDown, .brightnessUp, .brightnessDown, .zoomIn, .zoomOut,
         .jumpUp, .jumpDown, .jumpLeft, .jumpRight].contains(self)
    }

    /// One or two words for the on-screen button hints
    var shortTitle: String {
        switch self {
        case .leftClick: return "Select"
        case .rightClick: return "Options"
        case .escape: return "Back"
        case .spotlight: return "Search"
        case .keyboard: return "Keyboard"
        case .missionControl: return "Windows"
        case .appleDefault: return "Home"
        case .jumpUp, .jumpDown, .jumpLeft, .jumpRight: return "Move"
        case .voiceTyping: return "Voice"
        case .siri: return "Siri"
        case .previousDesktop: return "Desktop ←"
        case .nextDesktop: return "Desktop →"
        case .previousDisplay: return "Previous Display"
        case .nextDisplay: return "Next Display"
        default:
            return title.components(separatedBy: " (").first ?? title
        }
    }
}

struct Action: Codable, Hashable {
    var kind: ActionKind
    var custom: KeyShortcut?

    static let none = Action(kind: .none)
    init(kind: ActionKind, custom: KeyShortcut? = nil) {
        self.kind = kind
        self.custom = custom
    }

    var title: String {
        if kind == .shortcut, let c = custom { return "Shortcut " + KeyNames.describe(c) }
        return kind.title
    }
}

struct ButtonBinding: Codable, Hashable {
    var press: Action
    var hold: Action = .none
}

// MARK: - Named keys for custom shortcuts

enum KeyNames {
    static let all: [(String, UInt16)] = {
        let letters: [(String, UInt16)] = [("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
            ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
            ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)]
        let digits: [(String, UInt16)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22),
            ("7", 26), ("8", 28), ("9", 25), ("0", 29)]
        let special: [(String, UInt16)] = [("Return", 36), ("Esc", 53), ("Space", 49), ("Tab", 48),
            ("Delete", 51), ("↑", 126), ("↓", 125), ("←", 123), ("→", 124), ("-", 27), ("=", 24),
            ("[", 33), ("]", 30), (",", 43), (".", 47), ("/", 44), (";", 41), ("'", 39), ("`", 50),
            ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97), ("F7", 98),
            ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111)]
        return letters + digits + special
    }()

    static func name(_ code: UInt16) -> String { all.first { $0.1 == code }?.0 ?? "Key \(code)" }

    static func describe(_ s: KeyShortcut) -> String {
        (s.control ? "⌃" : "") + (s.option ? "⌥" : "") + (s.shift ? "⇧" : "") + (s.command ? "⌘" : "") + name(s.keyCode)
    }
}

// MARK: - Settings (saved to disk)

struct SettingsData: Codable {
    var enabled = true
    var profiles: [Profile] = [Defaults.playstationProfile, Defaults.xboxProfile]
    var activeProfileID: UUID = Defaults.playstationProfile.id
    var autoSwitchProfile = true
    var lightMode: LightMode = .solid

    var stickSpeed = 0.45          // 0…1
    var stickAcceleration = 0.6    // 0…1
    var scrollSpeed = 0.45
    var invertScroll = false
    var touchpadSpeed = 0.5

    var circleSize = 44.0
    var screenScale = 0.85         // 1 = off
    var keyboardKeySize = 64.0

    var rumble = true
    var scrollTicks = true

    var pauseInGames = true
    var extraGames: [String] = []
    var hintsMode: HintsMode = .autoHide
    var swipeTyping = true
    var largeSettingsWithController = true
    var autoUpdate = true
    /// Let the pointer cross to a neighbouring display anywhere along the shared side
    var crossAnyEdge = true
    var layoutVersion = 4
    var lightRed = 0.0, lightGreen = 0.35, lightBlue = 1.0

    init() {}

    private enum LegacyKeys: String, CodingKey { case base, quickMenu }

    // Tolerant decoding so new settings never wipe old ones
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsData()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        if let saved = try? c.decode([Profile].self, forKey: .profiles), !saved.isEmpty {
            profiles = saved
            activeProfileID = (try? c.decode(UUID.self, forKey: .activeProfileID)) ?? saved[0].id
            if !profiles.contains(where: { $0.id == activeProfileID }) { activeProfileID = saved[0].id }
        } else {
            // Earlier versions kept one layout; turn it into the PlayStation profile
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            var ps = Defaults.playstationProfile
            if let b = try? legacy?.decode([PadButton: ButtonBinding].self, forKey: .base) { ps.base = b }
            if let q = try? legacy?.decode([PadButton: ButtonBinding].self, forKey: .quickMenu) { ps.quickMenu = q }
            profiles = [ps, Defaults.xboxProfile]
            activeProfileID = ps.id
        }
        autoSwitchProfile = (try? c.decode(Bool.self, forKey: .autoSwitchProfile)) ?? d.autoSwitchProfile
        lightMode = (try? c.decode(LightMode.self, forKey: .lightMode)) ?? d.lightMode
        stickSpeed = (try? c.decode(Double.self, forKey: .stickSpeed)) ?? d.stickSpeed
        stickAcceleration = (try? c.decode(Double.self, forKey: .stickAcceleration)) ?? d.stickAcceleration
        scrollSpeed = (try? c.decode(Double.self, forKey: .scrollSpeed)) ?? d.scrollSpeed
        invertScroll = (try? c.decode(Bool.self, forKey: .invertScroll)) ?? d.invertScroll
        touchpadSpeed = (try? c.decode(Double.self, forKey: .touchpadSpeed)) ?? d.touchpadSpeed
        circleSize = (try? c.decode(Double.self, forKey: .circleSize)) ?? d.circleSize
        screenScale = (try? c.decode(Double.self, forKey: .screenScale)) ?? d.screenScale
        keyboardKeySize = (try? c.decode(Double.self, forKey: .keyboardKeySize)) ?? d.keyboardKeySize
        rumble = (try? c.decode(Bool.self, forKey: .rumble)) ?? d.rumble
        lightRed = (try? c.decode(Double.self, forKey: .lightRed)) ?? d.lightRed
        lightGreen = (try? c.decode(Double.self, forKey: .lightGreen)) ?? d.lightGreen
        lightBlue = (try? c.decode(Double.self, forKey: .lightBlue)) ?? d.lightBlue
        scrollTicks = (try? c.decode(Bool.self, forKey: .scrollTicks)) ?? d.scrollTicks
        pauseInGames = (try? c.decode(Bool.self, forKey: .pauseInGames)) ?? d.pauseInGames
        extraGames = (try? c.decode([String].self, forKey: .extraGames)) ?? d.extraGames
        hintsMode = (try? c.decode(HintsMode.self, forKey: .hintsMode)) ?? d.hintsMode
        swipeTyping = (try? c.decode(Bool.self, forKey: .swipeTyping)) ?? d.swipeTyping
        largeSettingsWithController = (try? c.decode(Bool.self, forKey: .largeSettingsWithController)) ?? d.largeSettingsWithController
        autoUpdate = (try? c.decode(Bool.self, forKey: .autoUpdate)) ?? d.autoUpdate
        crossAnyEdge = (try? c.decode(Bool.self, forKey: .crossAnyEdge)) ?? d.crossAnyEdge
        layoutVersion = (try? c.decode(Int.self, forKey: .layoutVersion)) ?? 1
        if layoutVersion < 2 { Defaults.upgradeToV2(&profiles); layoutVersion = 2 }
        if layoutVersion < 3 { Defaults.upgradeToV3(&profiles); layoutVersion = 3 }
        if layoutVersion < 4 { Defaults.upgradeToV4(&profiles); layoutVersion = 4 }
    }
}

enum Defaults {
    // Fixed IDs so the built-in profiles are recognisable
    static let playstationProfile = Profile(id: UUID(uuidString: "5A1C0DE0-0000-4000-8000-000000000001")!,
                                            name: "PlayStation", style: .playstation,
                                            base: base, quickMenu: quickMenu)
    static let xboxProfile = Profile(id: UUID(uuidString: "5A1C0DE0-0000-4000-8000-000000000002")!,
                                     name: "Xbox", style: .xbox, base: xboxBase, quickMenu: quickMenu)

    /// Xbox layout: A select, B back, X search, Y keyboard, Menu options, View screenshot, Xbox button home
    static let xboxBase: [PadButton: ButtonBinding] = {
        var m = base
        m[.touchpad] = b(.appleDefault)  // Share button on Series controllers
        m[.create] = b(.missionControl)  // View
        m[.ps] = b(.appleDefault)        // Xbox button
        return m
    }()

    /// Earlier versions used arrow keys on the D-pad and custom PS/Create actions. Move built-in
    /// profiles to the new defaults, but only where the user never changed the button.
    static func upgradeToV2(_ profiles: inout [Profile]) {
        let old: [PadButton: ButtonBinding] = [
            .up: b(.arrowUp), .down: b(.arrowDown), .left: b(.arrowLeft), .right: b(.arrowRight),
            .create: b(.screenshot, hold: .captureMenu), .ps: b(.missionControl, hold: .showDesktop),
            .triangle: b(.keyboard),
            .options: b(.rightClick),
        ]
        let oldXbox: [PadButton: ButtonBinding] = [
            .touchpad: b(.screenshot), .ps: b(.showDesktop, hold: .missionControl),
        ]
        for i in profiles.indices {
            let fresh = profiles[i].style == .xbox ? xboxBase : base
            for (button, oldBinding) in old.merging(profiles[i].style == .xbox ? oldXbox : [:], uniquingKeysWith: { $1 })
            where profiles[i].base[button] == oldBinding {
                profiles[i].base[button] = fresh[button]
            }
        }
    }

    /// 3.1 added "hold Options for Siri" (and hold △ to talk); layouts saved by 3.0 never got them.
    /// Add the hold only where the button still does exactly what it did by default.
    static func upgradeToV3(_ profiles: inout [Profile]) {
        for i in profiles.indices {
            let fresh = profiles[i].style == .xbox ? xboxBase : base
            for button in [PadButton.options, .triangle] {
                guard let current = profiles[i].base[button], let wanted = fresh[button],
                      current.hold.kind == .none, current.press == wanted.press else { continue }
                profiles[i].base[button] = wanted
            }
        }
    }

    /// 3.3 put desktops on Quick Menu L1/R1 and "next display" on Quick Menu L3,
    /// wherever those buttons still did what they did by default
    static func upgradeToV4(_ profiles: inout [Profile]) {
        let changes: [(PadButton, ActionKind, ActionKind)] = [
            (.l1, .reopenTab, .previousDesktop), (.r1, .newTab, .nextDesktop), (.l3, .reload, .nextDisplay)]
        for i in profiles.indices {
            for (button, old, new) in changes where profiles[i].quickMenu[button] == b(old) {
                profiles[i].quickMenu[button] = b(new)
            }
        }
    }

    static func b(_ k: ActionKind, hold: ActionKind = .none) -> ButtonBinding {
        ButtonBinding(press: Action(kind: k), hold: Action(kind: hold))
    }

    /// The PS5-style layout
    static let base: [PadButton: ButtonBinding] = [
        .cross: b(.leftClick),
        .circle: b(.escape, hold: .closeWindow),
        .square: b(.spotlight),
        .triangle: b(.keyboard, hold: .voiceTyping),
        .l1: b(.previousTab),
        .r1: b(.nextTab),
        .l2: b(.none),                      // holds the Quick Menu
        .r2: b(.enter),
        .up: b(.jumpUp), .down: b(.jumpDown), .left: b(.jumpLeft), .right: b(.jumpRight),
        .options: b(.rightClick, hold: .siri),
        .create: b(.appleDefault),          // macOS takes the screenshot / clip
        .ps: b(.appleDefault),              // macOS game overlay / Apps
        .l3: b(.finder),
        .r3: b(.delete),
        .touchpad: b(.leftClick),
    ]

    /// While L2 is held
    static let quickMenu: [PadButton: ButtonBinding] = [
        .square: b(.copy),
        .triangle: b(.paste),
        .cross: b(.selectAll),
        .circle: b(.undo),
        .r2: b(.redo),
        .r1: b(.nextDesktop),
        .l1: b(.previousDesktop),
        .left: b(.pageBack),
        .right: b(.pageForward),
        .up: b(.volumeUp),
        .down: b(.volumeDown),
        .options: b(.quitApp),
        .create: b(.fullScreen),
        .ps: b(.lastApp),
        .l3: b(.nextDisplay),
        .r3: b(.find),
        .touchpad: b(.playPause),
    ]
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var data: SettingsData
    private var saveSub: AnyCancellable?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Console Mode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private init() {
        if let raw = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = decoded
        } else {
            data = SettingsData()
        }
        // Save shortly after changes settle (sliders change many times a second)
        saveSub = $data.dropFirst().debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    func saveNow() { save() }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let raw = try? enc.encode(data) { try? raw.write(to: Self.fileURL, options: .atomic) }
    }

    var activeIndex: Int {
        data.profiles.firstIndex { $0.id == data.activeProfileID } ?? 0
    }

    /// The app in front (kept up to date by the app delegate) — not saved
    var frontmostBundleID: String?

    /// The profile in use right now: one assigned to the front app, otherwise the active one
    var effectiveProfile: Profile {
        if let id = frontmostBundleID, let p = data.profiles.first(where: { $0.apps.contains(id) }) { return p }
        return activeProfile
    }

    var activeProfile: Profile {
        get { data.profiles[activeIndex] }
        set { data.profiles[activeIndex] = newValue }
    }

    /// What the button does right now (respects per-app profiles)
    func binding(for button: PadButton, quickMenu: Bool) -> ButtonBinding {
        let p = effectiveProfile
        let table = quickMenu ? p.quickMenu : p.base
        return table[button] ?? ButtonBinding(press: .none)
    }

    /// The button as set in the profile being edited in Settings
    func editingBinding(for button: PadButton, quickMenu: Bool) -> ButtonBinding {
        let p = activeProfile
        let table = quickMenu ? p.quickMenu : p.base
        return table[button] ?? ButtonBinding(press: .none)
    }

    func setBinding(_ b: ButtonBinding, for button: PadButton, quickMenu: Bool) {
        let i = activeIndex
        if quickMenu { data.profiles[i].quickMenu[button] = b } else { data.profiles[i].base[button] = b }
    }

    func resetButtons() {
        let i = activeIndex
        let d = data.profiles[i].style == .xbox ? Defaults.xboxProfile : Defaults.playstationProfile
        data.profiles[i].base = d.base
        data.profiles[i].quickMenu = d.quickMenu
    }

    /// Switch to a profile made for this kind of controller, if the current one isn't
    func autoSelect(for style: ControllerStyle) {
        guard data.autoSwitchProfile, activeProfile.style != style,
              let match = data.profiles.first(where: { $0.style == style }) else { return }
        data.activeProfileID = match.id
    }

    func duplicateActive() {
        var copy = activeProfile
        copy.id = UUID()
        copy.name = activeProfile.name + " Copy"
        data.profiles.append(copy)
        data.activeProfileID = copy.id
    }

    func deleteProfile(_ id: UUID) {
        guard data.profiles.count > 1 else { return }
        data.profiles.removeAll { $0.id == id }
        if !data.profiles.contains(where: { $0.id == data.activeProfileID }) {
            data.activeProfileID = data.profiles[0].id
        }
    }

    /// Imports one or more .json profile files. Returns how many were added.
    @discardableResult
    func importProfiles(from urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            guard let raw = try? Data(contentsOf: url) else { continue }
            var incoming: [Profile] = []
            if let one = try? JSONDecoder().decode(Profile.self, from: raw), !one.base.isEmpty || !one.quickMenu.isEmpty {
                incoming = [one]
            } else if let many = try? JSONDecoder().decode([Profile].self, from: raw) {
                incoming = many
            }
            for var p in incoming {
                p.id = UUID()   // never clash with an existing profile
                if p.name == "Imported Profile" { p.name = url.deletingPathExtension().lastPathComponent }
                data.profiles.append(p)
                added += 1
            }
        }
        if added > 0, let last = data.profiles.last { data.activeProfileID = last.id }
        return added
    }

    func exportData(for id: UUID) -> Data? {
        guard let p = data.profiles.first(where: { $0.id == id }) else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(p)
    }
}
