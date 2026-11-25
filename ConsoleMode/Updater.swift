import AppKit

/// Checks GitHub Releases for a newer Console Mode, downloads it, makes sure it's signed with
/// the same certificate, swaps it in and relaunches. No Terminal commands needed.
final class Updater: ObservableObject {
    static let repo = "natehale05-gif/ControllerCursor"
    /// Every real build is signed with this certificate; anything else is refused
    static let signingRequirement = #"certificate leaf = H"7e003be47e971485c26b551c133545e48857bd9a""#

    @Published var status = ""
    @Published var busy = false
    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private var timer: Timer?

    func startAutomaticChecks(enabled: @escaping () -> Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if enabled() { self?.check(install: true, quiet: true) }
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            if enabled() { self?.check(install: true, quiet: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check(install: Bool, quiet: Bool = false) {
        guard !busy else { return }
        busy = true
        status = "Checking…"
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.busy = false
                    self.status = code == 404
                        ? "Updates aren't available yet (the GitHub repo is private)."
                        : "Couldn't check for updates."
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Self.isNewer(latest, than: self.current) else {
                    self.busy = false
                    self.status = "Console Mode is up to date (\(self.current))."
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else {
                    self.busy = false
                    self.status = "Version \(latest) is out, but its download is missing."
                    return
                }
                if install {
                    self.status = "Downloading version \(latest)…"
                    self.download(url, version: latest)
                } else {
                    self.busy = false
                    self.status = "Version \(latest) is available."
                }
                _ = quiet
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func download(_ url: URL, version: String) {
        URLSession.shared.downloadTask(with: url) { [weak self] file, _, _ in
            guard let self else { return }
            guard let file else { self.finish("Download failed."); return }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ConsoleModeUpdate-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try? FileManager.default.moveItem(at: file, to: zip)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else {
                self.finish("Couldn't unpack the update."); return
            }
            let newApp = work.appendingPathComponent("Console Mode.app")
            guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "-R=\(Self.signingRequirement)", newApp.path]) == 0 else {
                self.finish("The update's signature didn't match, so it wasn't installed."); return
            }
            DispatchQueue.main.async { self.install(newApp, version: version) }
        }.resume()
    }

    /// macOS runs apps opened straight from Downloads from a hidden read-only copy ("App Translocation"),
    /// which can't update itself and loses its permissions
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// Where Console Mode should live: where it is now, or Applications if it's somewhere it can't stay
    private static func installLocation() -> URL {
        let current = Bundle.main.bundleURL
        if !isTranslocated, FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) {
            return current
        }
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder = FileManager.default.isWritableFile(atPath: system.path) ? system
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Console Mode.app")
    }

    /// Puts `newApp` where Console Mode belongs and restarts into it
    private func place(_ newApp: URL) -> String? {
        let dest = Self.installLocation()
        let fm = FileManager.default
        Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        let backup = dest.deletingLastPathComponent().appendingPathComponent(".Console Mode (old).app")
        do {
            try? fm.removeItem(at: backup)
            if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: backup) }
            try fm.moveItem(at: newApp, to: dest)
        } catch {
            if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: backup, to: dest) }
            return error.localizedDescription
        }
        if fm.fileExists(atPath: backup.path) { NSWorkspace.shared.recycle([backup]) { _, _ in } }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this copy has fully quit (it restores the screen size first), then open the new one
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          dest.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        return nil
    }

    private func install(_ newApp: URL, version: String) {
        if let error = place(newApp) {
            finish("Couldn't install the update: \(error)")
            return
        }
        status = "Updated to \(version). Restarting…"
    }

    /// Offer to move a translocated copy into Applications, where it can update and keep its permissions
    func offerMoveToApplications() {
        guard Self.isTranslocated else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Console Mode to Applications?"
        alert.informativeText = "It's running from a temporary copy macOS made when it was opened from Downloads, so it can't update itself or keep its Accessibility permission. Afterwards you can delete the copy in Downloads."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ConsoleModeMove-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let copy = temp.appendingPathComponent("Console Mode.app")
        // ditto keeps the code signature intact
        guard Self.run("/usr/bin/ditto", [Bundle.main.bundlePath, copy.path]) == 0, place(copy) == nil else {
            let fail = NSAlert()
            fail.messageText = "Couldn't move Console Mode"
            fail.informativeText = "Drag it from Downloads into Applications in Finder, then open it from there."
            fail.runModal()
            return
        }
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.busy = false
            self.status = message
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
