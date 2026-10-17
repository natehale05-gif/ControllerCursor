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

    private func install(_ newApp: URL, version: String) {
        let currentApp = Bundle.main.bundleURL
        let backup = currentApp.deletingLastPathComponent().appendingPathComponent(".Console Mode (old).app")
        do {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: currentApp, to: backup)
            try FileManager.default.moveItem(at: newApp, to: currentApp)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: currentApp)
            finish("Couldn't replace the app: \(error.localizedDescription)")
            return
        }
        NSWorkspace.shared.recycle([backup]) { _, _ in }
        status = "Updated to \(version). Restarting…"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this copy has fully quit (it restores the screen size first), then open the new one
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          currentApp.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
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
