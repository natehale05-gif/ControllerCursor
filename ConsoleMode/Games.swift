import AppKit

/// Decides whether the app in front is a game, so Console Mode can step aside and let
/// the game read the controller directly (the way Apple intends).
enum GameDetector {
    /// Apps that handle controllers themselves
    static let builtIn: Set<String> = [
        "com.valvesoftware.steam",          // Steam / Big Picture
        "com.apple.games",                  // Apple Games
        "com.nvidia.gfnpc.mall",            // GeForce NOW
        "com.epicgames.EpicGamesLauncher",
        "com.blizzard.bnetlauncher",
        "com.heroicgameslauncher.hgl",
        "com.isaacmarovitz.Whisky",
        "com.codeweavers.CrossOver",
        "org.openemu.OpenEmu",
        "org.dolphin-emu.dolphin",
        "net.pcsx2.pcsx2",
        "org.ppsspp.ppsspp",
    ]

    private static var cache: [String: Bool] = [:]

    static func isGame(_ app: NSRunningApplication?, extra: [String]) -> Bool {
        guard let app else { return false }
        // Windows games through Wine / CrossOver / Whisky, and Steam games without a bundle ID
        if let exe = app.executableURL?.path.lowercased(),
           exe.contains("wine") || exe.contains("crossover") || exe.contains("whisky") || exe.contains("/steamapps/common/") {
            return true
        }
        guard let id = app.bundleIdentifier else { return false }
        if extra.contains(id) || builtIn.contains(id) { return true }
        if let known = cache[id] { return known }
        var game = false
        if let url = app.bundleURL {
            // Steam and other launchers install games in folders like these
            let path = url.path.lowercased()
            if path.contains("/steamapps/common/") || path.contains("/epic games/") { game = true }
            // The App Store category every game declares
            if !game, let info = Bundle(url: url)?.infoDictionary,
               let category = info["LSApplicationCategoryType"] as? String {
                game = category.lowercased().contains("games")
            }
        }
        cache[id] = game
        return game
    }
}
