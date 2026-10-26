import AppKit
import os

// Mises à jour depuis les Releases GitHub (dépôt public, aucune clé nécessaire).
// La release doit contenir « OsaWallpaper.zip » (l'app zippée avec ditto).
// Avant de remplacer l'app, on vérifie que la nouvelle est signée par la même équipe.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "osayanis/osawallpaper"

    struct Release { let version: String; let notes: String; let zip: URL; let page: URL }

    @Published var available: Release?
    @Published var busy = false
    @Published var lastError: String?

    private let ulog = Logger(subsystem: "com.osalabs.osawallpaper", category: "update")
    private var timer: Timer?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Vérifie au lancement puis toutes les 12 h (si l'option est active).
    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.autoCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
    }

    private func autoCheck() {
        guard Prefs.shared.autoUpdate else { return }
        check { [weak self] r in if let r { self?.propose(r, manual: false) } }
    }

    /// « Rechercher des mises à jour… » : répond toujours, même s'il n'y a rien.
    func checkNow() {
        check { [weak self] r in
            guard let self else { return }
            if let r { self.propose(r, manual: true); return }
            let a = NSAlert()
            if let e = self.lastError {
                a.messageText = "Impossible de vérifier les mises à jour"
                a.informativeText = e
            } else {
                a.messageText = "OsaWallpaper est à jour"
                a.informativeText = "Tu as la dernière version (\(Self.current))."
            }
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    func check(_ done: @escaping (Release?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OsaWallpaper/\(Self.current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var found: Release?
            var error: String?
            if let err { error = err.localizedDescription }
            else if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tag = j["tag_name"] as? String {
                let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let assets = j["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
                if Self.newer(v, than: Self.current), let zip, let u = URL(string: zip) {
                    found = Release(version: v, notes: j["body"] as? String ?? "", zip: u,
                                    page: URL(string: j["html_url"] as? String ?? "") ?? u)
                }
            } else {
                error = "Réponse inattendue de GitHub (code \((resp as? HTTPURLResponse)?.statusCode ?? 0))."
            }
            DispatchQueue.main.async {
                self.lastError = error
                self.available = found
                done(found)
            }
        }.resume()
    }

    /// Compare « 0.10.1 » et « 0.9 » nombre par nombre.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func propose(_ r: Release, manual: Bool) {
        let a = NSAlert()
        a.messageText = "OsaWallpaper \(r.version) est disponible"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "Tu as la version \(Self.current).\n\n" + (notes.count > 600 ? String(notes.prefix(600)) + "…" : notes)
        a.addButton(withTitle: "Installer et relancer")
        a.addButton(withTitle: "Plus tard")
        a.addButton(withTitle: "Voir sur GitHub")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    // MARK: Installation

    func install(_ r: Release) {
        guard !busy else { return }
        busy = true
        URLSession.shared.downloadTask(with: r.zip) { tmp, _, err in
            do {
                guard let tmp else { throw Fail(err?.localizedDescription ?? "Téléchargement impossible.") }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OsaWallpaper-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let zip = dir.appendingPathComponent("OsaWallpaper.zip")
                try FileManager.default.moveItem(at: tmp, to: zip)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
                let app = dir.appendingPathComponent("OsaWallpaper.app")
                guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw Fail("L'archive ne contient pas OsaWallpaper.") }
                guard let team = Self.team(of: app), team == Self.team(of: Bundle.main.bundleURL) else {
                    throw Fail("La signature de la nouvelle version ne correspond pas : installation annulée.")
                }
                try Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                DispatchQueue.main.async { self.relaunch(with: app) }
            } catch {
                self.ulog.error("mise à jour échouée : \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.busy = false
                    let a = NSAlert(); a.messageText = "La mise à jour a échoué"; a.informativeText = error.localizedDescription
                    NSApp.activate(ignoringOtherApps: true); a.runModal()
                }
            }
        }.resume()
    }

    /// Un petit script attend la fin de l'app, remplace le paquet puis la relance.
    private func relaunch(with app: URL) {
        let dest = Bundle.main.bundlePath
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(dest).old" && mv "\(dest)" "\(dest).old" && /usr/bin/ditto "\(app.path)" "\(dest)" && rm -rf "\(dest).old" || mv "\(dest).old" "\(dest)"
        open "\(dest)"
        rm -rf "\(app.deletingLastPathComponent().path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do { try p.run() } catch { busy = false; return }
        NSApp.terminate(nil)
    }

    /// Identifiant d'équipe de la signature (« ad-hoc » pour une signature locale).
    static func team(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String ?? "ad-hoc"
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 && tool != "/usr/bin/xattr" { throw Fail("\(tool) a échoué (\(p.terminationStatus)).") }
        return p.terminationStatus
    }

    struct Fail: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }
}
