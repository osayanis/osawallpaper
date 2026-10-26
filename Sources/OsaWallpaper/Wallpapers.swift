import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import WebKit
import os

// Fonds d'écran personnalisés de l'écran verrouillé : photo, vidéo (fichier, lien .mp4,
// vidéos aériennes d'Apple) ou vidéo YouTube (lecteur intégré officiel, en direct).

struct Wallpaper: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, video, youtube }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var thumb: URL?            // miniature (distante ou locale)
    var remote: URL?           // source pleine qualité à télécharger
    var local: String?         // fichier une fois téléchargé (Application Support)
    var youtubeID: String?
    var badge: String?         // « 4K », « Vidéo »…

    var localURL: URL? { local.map { URL(fileURLWithPath: $0) } }
    var isReady: Bool { kind == .youtube || localURL.map { FileManager.default.fileExists(atPath: $0.path) } == true }
}

private let wlog = Logger(subsystem: "com.osalabs.osawallpaper", category: "wallpapers")

final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()

    @Published private(set) var current: Wallpaper?
    @Published private(set) var history: [Wallpaper] = []
    @Published private(set) var progress: [String: Double] = [:]     // téléchargements en cours (0…1)
    @Published private(set) var image: NSImage?                       // photo actuelle, décodée une fois
    @Published var error: String?
    let player = MotionPlayer()                                        // vidéo actuelle, partagée par les écrans

    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Demo.on ? "OsaWallpaper-Demo/Wallpapers" : "OsaWallpaper/Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var stateFile: URL { Self.dir.deletingLastPathComponent().appendingPathComponent("wallpapers.json") }
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observers: [String: NSKeyValueObservation] = [:]

    private struct State: Codable { var current: Wallpaper?; var history: [Wallpaper] }

    private init() {
        if let d = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(State.self, from: d) {
            history = s.history.filter { $0.isReady }
            if let c = s.current, c.isReady { setCurrent(c, save: false) }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(State(current: current, history: history)) { try? d.write(to: stateFile) }
    }

    private func setCurrent(_ w: Wallpaper?, save doSave: Bool = true) {
        current = w
        image = nil
        player.load(nil)
        switch w?.kind {
        case .image: image = w?.localURL.flatMap { NSImage(contentsOf: $0) }
        case .video: player.load(w?.localURL)
        default: break
        }
        if doSave { save() }
    }

    /// Utilise ce fond (le télécharge d'abord si besoin).
    func apply(_ w: Wallpaper) {
        error = nil
        if w.isReady { commit(w); return }
        guard let src = w.remote, tasks[w.id] == nil else { return }
        let ext = src.pathExtension.isEmpty ? (w.kind == .video ? "mp4" : "jpg") : src.pathExtension
        let dest = Self.dir.appendingPathComponent(w.id.replacingOccurrences(of: "/", with: "-") + "." + ext)
        var req = URLRequest(url: src)
        req.setValue("OsaWallpaper (https://github.com/osayanis/osawallpaper)", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.downloadTask(with: req) { [weak self] tmp, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var ok = false
            if let tmp, err == nil, (200..<300).contains(code) {
                try? FileManager.default.removeItem(at: dest)
                ok = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tasks[w.id] = nil; self.observers[w.id] = nil; self.progress[w.id] = nil
                if ok {
                    var r = w; r.local = dest.path
                    self.commit(r)
                } else if (err as? URLError)?.code != .cancelled {
                    self.error = "Téléchargement impossible (\(err?.localizedDescription ?? "erreur \(code)"))."
                    wlog.error("téléchargement échoué : \(src.absoluteString, privacy: .public)")
                }
            }
        }
        observers[w.id] = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { if self?.tasks[w.id] != nil { self?.progress[w.id] = p.fractionCompleted } }
        }
        tasks[w.id] = task
        progress[w.id] = 0
        task.resume()
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    private func commit(_ w: Wallpaper) {
        var w = w
        if w.kind == .video, w.thumb == nil, let f = w.localURL { w.thumb = Self.videoThumb(f, id: w.id) }
        history.removeAll { $0.id == w.id }
        history.insert(w, at: 0)
        // On garde les 40 derniers ; les fichiers des plus anciens sont supprimés.
        while history.count > 40 { if let f = history.removeLast().localURL { try? FileManager.default.removeItem(at: f) } }
        setCurrent(w)
    }

    func clear() { setCurrent(nil) }

    /// Les photos choisies avant que leur nom soit connu le reçoivent ici.
    func applyNames(_ names: [String: PhotoName]) {
        func fix(_ w: Wallpaper) -> Wallpaper {
            guard w.id.hasPrefix("wh-"), let n = names[String(w.id.dropFirst(3))], n.title != w.title else { return w }
            var r = w; r.title = n.title; r.subtitle = n.credit ?? w.subtitle
            return r
        }
        let h = history.map(fix), c = current.map(fix)
        guard h != history || c != current else { return }
        history = h; current = c
        save()
    }

    /// Identifiants Wallhaven des fonds sans nom (à demander).
    var unnamedPhotos: [String] {
        history.filter { $0.id.hasPrefix("wh-") && $0.title.hasPrefix("Photo") }.map { String($0.id.dropFirst(3)) }
    }

    func remove(_ w: Wallpaper) {
        if current?.id == w.id { setCurrent(nil, save: false) }
        history.removeAll { $0.id == w.id }
        for f in [w.localURL, w.thumb].compactMap({ $0 }) where f.isFileURL && f.path.hasPrefix(Self.dir.path) {
            try? FileManager.default.removeItem(at: f)
        }
        save()
    }

    /// Fichier choisi sur le Mac : copié dans le dossier de l'app (l'original peut bouger).
    func importFile(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        let isVideo = type?.conforms(to: .movie) == true
        guard isVideo || type?.conforms(to: .image) == true else { error = "Ce fichier n'est ni une image ni une vidéo."; return }
        let id = "file-" + Self.stableID(url.path)
        let dest = Self.dir.appendingPathComponent(id + "." + url.pathExtension.lowercased())
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { self.error = "Impossible de copier ce fichier."; return }
        commit(Wallpaper(id: id, kind: isVideo ? .video : .image, title: url.deletingPathExtension().lastPathComponent,
                         subtitle: "Depuis ton Mac", thumb: isVideo ? nil : dest, local: dest.path, badge: isVideo ? "Vidéo" : nil))
    }

    /// Lien collé : YouTube (lu en direct) ou vidéo / image directe (téléchargée une fois).
    static func fromLink(_ text: String) -> Wallpaper? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = youtubeID(s) {
            return Wallpaper(id: "yt-" + id, kind: .youtube, title: "Vidéo YouTube", subtitle: "Lue en direct, en sourdine",
                             thumb: URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg"), youtubeID: id, badge: "YouTube")
        }
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        let ext = u.pathExtension.lowercased()
        let video = ["mp4", "mov", "m4v"].contains(ext)
        guard video || ["jpg", "jpeg", "png", "heic", "webp"].contains(ext) else { return nil }
        return Wallpaper(id: "url-" + stableID(s), kind: video ? .video : .image,
                         title: u.deletingPathExtension().lastPathComponent, subtitle: u.host,
                         thumb: video ? nil : u, remote: u, badge: video ? "Vidéo" : nil)
    }

    /// Image tirée de la vidéo (1 s) pour la galerie.
    static func videoThumb(_ f: URL, id: String) -> URL? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: f))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 640, height: 640)
        guard let cg = try? g.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil),
              let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        let out = dir.appendingPathComponent(id + "-thumb.jpg")
        return (try? jpg.write(to: out)) != nil ? out : nil
    }

    /// Même texte → même identifiant, d'un lancement à l'autre (hashValue change à chaque lancement).
    static func stableID(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(format: "%08x", h)
    }

    /// Titre et chaîne de la vidéo (oEmbed). nil si elle n'existe pas ou refuse l'intégration.
    static func youtubeInfo(_ w: Wallpaper) async -> Wallpaper? {
        guard let id = w.youtubeID, let u = URL(string: "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(id)") else { return nil }
        guard let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var out = w
        if let t = j["title"] as? String { out.title = t }
        if let a = j["author_name"] as? String { out.subtitle = "YouTube · " + a }
        return out
    }

    /// youtube.com/watch?v=…, youtu.be/…, /shorts/…, /embed/…, /live/…
    static func youtubeID(_ s: String) -> String? {
        guard let u = URLComponents(string: s), let host = u.host?.lowercased(), host.contains("youtu") else { return nil }
        let valid = { (id: String) -> String? in id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? id : nil }
        if host.contains("youtu.be") { return valid(String(u.path.dropFirst()).components(separatedBy: "/")[0]) }
        if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { return valid(v) }
        let parts = u.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) { return valid(parts[1]) }
        return nil
    }
}

// MARK: - Photos (Wallhaven : base libre, sans clé, filtrée « tout public »)

enum Wallhaven {
    struct Item: Decodable, Identifiable {
        let id: String, path: String, resolution: String, file_size: Int, colors: [String]
        let thumbs: Thumbs
        struct Thumbs: Decodable { let large: String, original: String, small: String }
        var width: Int { Int(resolution.split(separator: "x").first ?? "") ?? 0 }
        func wallpaper(_ n: PhotoName?) -> Wallpaper {
            let size = ByteCountFormatter.string(fromByteCount: Int64(file_size), countStyle: .file)
            return Wallpaper(id: "wh-" + id, kind: .image, title: n?.title ?? "Photo",
                             subtitle: n?.credit ?? "Wallhaven · " + resolution.replacingOccurrences(of: "x", with: " × ") + " · " + size,
                             thumb: URL(string: thumbs.large), remote: URL(string: path), badge: width >= 3840 ? "4K" : width >= 2560 ? "QHD" : nil)
        }
    }
    struct Page: Decodable { let data: [Item]; let meta: Meta; struct Meta: Decodable { let current_page: Int; let last_page: Int } }

    /// Thèmes proposés (requête en anglais : c'est la langue des mots-clés de Wallhaven).
    static let topics: [(label: String, q: String, icon: String)] = [
        ("Tendances", "landscape", "flame.fill"), ("Nature", "nature", "leaf.fill"), ("Montagnes", "mountains", "mountain.2.fill"),
        ("Espace", "space", "sparkles"), ("Océan", "ocean", "water.waves"), ("Villes", "city", "building.2.fill"),
        ("Nuit", "night", "moon.stars.fill"), ("Coucher de soleil", "sunset", "sun.horizon.fill"),
        ("Minimaliste", "minimalism", "circle.lefthalf.filled"), ("Abstrait", "abstract", "scribble.variable"),
        ("Voitures", "cars", "car.fill"), ("Forêt", "forest", "tree.fill"),
    ]

    /// Wallhaven classe parfois des illustrations suggestives en « tout public » : on les écarte.
    static let exclude = " -women -girl -anime -feet -legs -model -bikini -lingerie"

    static func search(_ q: String, page: Int) async throws -> Page {
        // OSAWALLPAPER_DEMO_PHOTOS=<page.json> : photos locales (captures pour le site, photos libres de droits)
        if Demo.on, let f = ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO_PHOTOS"] {
            return try JSONDecoder().decode(Page.self, from: Data(contentsOf: URL(fileURLWithPath: f)))
        }
        var c = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        c.queryItems = [
            .init(name: "q", value: q + exclude), .init(name: "categories", value: "100"), .init(name: "purity", value: "100"),
            .init(name: "sorting", value: "toplist"), .init(name: "topRange", value: q == "landscape" ? "6M" : "1y"),
            .init(name: "atleast", value: "2560x1440"), .init(name: "ratios", value: "landscape"), .init(name: "page", value: String(page)),
        ]
        var r = URLRequest(url: c.url!, timeoutInterval: 20)
        r.setValue("OsaWallpaper (https://github.com/osayanis/osawallpaper)", forHTTPHeaderField: "User-Agent")
        let (d, _) = try await URLSession.shared.data(for: r)
        return try JSONDecoder().decode(Page.self, from: d)
    }
}

// MARK: - Vidéos aériennes d'Apple (celles de l'Apple TV et de l'économiseur d'écran)

enum AppleAerials {
    struct Item: Identifiable {
        let id: String, title: String, subtitle: String, categories: [String], video: URL, snapshot: URL
        var wallpaper: Wallpaper {
            Wallpaper(id: "aerial-" + id, kind: .video, title: title, subtitle: subtitle, thumb: snapshot, remote: video, badge: "Vidéo")
        }
    }
    struct Catalog { let items: [Item]; let categories: [(id: String, name: String)] }

    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.osalabs.osawallpaper/aerials", isDirectory: true)

    /// Catalogue public d'Apple (≈ 2 Mo, gardé une semaine en cache).
    static func load() async throws -> Catalog {
        let fm = FileManager.default
        let entries = cache.appendingPathComponent("entries.json")
        let fresh = (try? entries.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false
        if !fresh {
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let (tar, _) = try await URLSession.shared.download(from: URL(string: "https://sylvan.apple.com/Aerials/resources-16.tar")!)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xf", tar.path, "-C", cache.path, "entries.json", "TVIdleScreenStrings.bundle"]
            try p.run(); p.waitUntilExit()
            try? fm.removeItem(at: tar)
        }
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: entries)) as? [String: Any] ?? [:]
        let strings = localizedStrings()
        let cats = (j["categories"] as? [[String: Any]] ?? []).compactMap { c -> (String, String)? in
            guard let id = c["id"] as? String, let key = c["localizedNameKey"] as? String else { return nil }
            return (id, strings[key] ?? key.replacingOccurrences(of: "AerialCategory", with: ""))
        }
        let items = (j["assets"] as? [[String: Any]] ?? []).compactMap { a -> Item? in
            guard let id = a["id"] as? String, let shot = a["shotID"] as? String,
                  let v = (a["url-1080-SDR"] ?? a["url-1080-H264"]) as? String, let video = URL(string: v) else { return nil }
            let poi = (a["pointsOfInterest"] as? [String: String])?.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.first?.value
            let sub = poi.flatMap { strings[$0] }?.replacingOccurrences(of: "\n", with: " ") ?? ""
            return Item(id: id, title: a["accessibilityLabel"] as? String ?? shot, subtitle: sub,
                        categories: a["categories"] as? [String] ?? [], video: video,
                        snapshot: URL(string: "https://sylvan.apple.com/Aerials/jjGqDwCNrOsVJ4of6uSVr/snapshots/\(shot).jpg")!)
        }
        return Catalog(items: items, categories: cats)
    }

    /// Noms et descriptions dans la langue du Mac (français si disponible).
    private static func localizedStrings() -> [String: String] {
        let bundle = cache.appendingPathComponent("TVIdleScreenStrings.bundle")
        for lang in Locale.preferredLanguages.map({ String($0.prefix(2)) }) + ["fr", "en"] {
            let f = bundle.appendingPathComponent("\(lang).lproj/Localizable.nocache.strings")
            if let d = NSDictionary(contentsOf: f) as? [String: String] { return d }
        }
        return [:]
    }
}

// MARK: - Lecteur YouTube

/// Lecteur officiel de YouTube (intégration youtube-nocookie), en sourdine, en boucle, sans
/// commandes, agrandi pour remplir l'écran. Créé seulement quand l'écran verrouillé est visible.
struct YouTubeView: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.setValue(false, forKey: "drawsBackground")
        load(v, context.coordinator)
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        if context.coordinator.id != id { load(v, context.coordinator) }
    }

    func makeCoordinator() -> Box { Box() }
    final class Box { var id = "" }

    static func dismantleNSView(_ v: WKWebView, coordinator: Box) {
        v.loadHTMLString("", baseURL: nil)   // coupe la vidéo tout de suite
    }

    private func load(_ v: WKWebView, _ box: Box) {
        box.id = id
        let params = "autoplay=1&mute=1&loop=1&playlist=\(id)&controls=0&disablekb=1&fs=0&rel=0&iv_load_policy=3&playsinline=1&modestbranding=1"
        let html = """
        <!doctype html><html><head><meta name="referrer" content="strict-origin-when-cross-origin"><style>
        html,body{margin:0;height:100%;overflow:hidden;background:transparent}
        iframe{position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-height:100vh;min-width:177.78vh;
        transform:translate(-50%,-50%) scale(1.14);border:0;pointer-events:none}
        </style></head><body><iframe src="https://www.youtube-nocookie.com/embed/\(id)?\(params)"
        allow="autoplay; encrypted-media" referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        // Une origine est nécessaire : sans « Referer », YouTube refuse la lecture (erreur 153).
        v.loadHTMLString(html, baseURL: URL(string: "https://osalabs.fr/"))
    }
}
