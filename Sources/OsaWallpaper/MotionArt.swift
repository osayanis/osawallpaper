import Foundation
import AVFoundation
import SwiftUI
import os

// Pochettes animées d'Apple Music (celles de l'iPhone), quand l'artiste en a fait une.
// Pas d'API publique : la page de l'album sur music.apple.com contient, dans son JSON
// « serialized-server-data », une vidéo HLS par format (carré, vertical). Chaque qualité
// est un seul fichier MP4 fragmenté : on le télécharge une fois et on le garde en cache,
// pour ne pas streamer en boucle pendant des heures. Méthode non officielle : si Apple
// change sa page, on retombe simplement sur la pochette fixe.
enum MotionArt {
    private static let mlog = Logger(subsystem: "com.osalabs.osawallpaper", category: "motion")
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static var misses = Set<String>()   // albums sans pochette animée (pas de nouvelle requête)

    static let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.osalabs.osawallpaper/motion", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Fichier vidéo local de la pochette animée de l'album, ou nil s'il n'y en a pas.
    static func find(artist: String, album: String) async -> URL? {
        let key = "\(artist)|\(album)".lowercased()
        guard !album.isEmpty, !misses.contains(key) else { return nil }
        let file = cacheDir.appendingPathComponent(String(format: "%08x", stableHash(key)) + ".mp4")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        do {
            guard let page = try await albumPage(artist: artist, album: album),
                  let master = try await squareVideo(page),
                  let mp4 = try await bestVariant(master) else { misses.insert(key); return nil }
            let (tmp, _) = try await URLSession.shared.download(from: mp4)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            trimCache()
            mlog.notice("pochette animée en cache : \(album, privacy: .public)")
            return file
        } catch {
            mlog.error("pochette animée : \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Page music.apple.com de l'album (via l'API de recherche iTunes, même pays que le Mac).
    private static func albumPage(artist: String, album: String) async throws -> URL? {
        let country = (Locale.current.region?.identifier ?? "fr").lowercased()
        let cleanAlbum = MusicWatcher.cleanTrack(album)
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(MusicWatcher.cleanArtist(artist)) \(cleanAlbum)"),
                        .init(name: "entity", value: "album"), .init(name: "limit", value: "5"), .init(name: "country", value: country)]
        let (d, _) = try await URLSession.shared.data(from: c.url!)
        let results = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        // On n'accepte qu'un album dont le nom correspond : mieux vaut rien qu'une mauvaise vidéo.
        let want = norm(cleanAlbum)
        let hit = results.first { norm(MusicWatcher.cleanTrack($0["collectionName"] as? String ?? "")) == want }
            ?? results.first { let n = norm($0["collectionName"] as? String ?? ""); return !want.isEmpty && (n.hasPrefix(want) || want.hasPrefix(n)) }
        guard let s = hit?["collectionViewUrl"] as? String, let u = URL(string: s.components(separatedBy: "?")[0]) else { return nil }
        return u
    }

    /// URL HLS de la vidéo carrée (« motionDetailSquare ») trouvée dans la page.
    private static func squareVideo(_ page: URL) async throws -> URL? {
        var r = URLRequest(url: page, timeoutInterval: 20)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (d, _) = try await URLSession.shared.data(for: r)
        guard let html = String(data: d, encoding: .utf8),
              let start = html.range(of: "id=\"serialized-server-data\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) else { return nil }
        func walk(_ o: Any) -> String? {
            if let d = o as? [String: Any] {
                if let sq = d["motionDetailSquare"] as? [String: Any], let v = sq["video"] as? String { return v }
                for v in d.values { if let f = walk(v) { return f } }
            } else if let a = o as? [Any] {
                for v in a { if let f = walk(v) { return f } }
            }
            return nil
        }
        return walk(json).flatMap(URL.init(string:))
    }

    /// Choisit une qualité 1080p (HEVC de préférence, débit raisonnable) et renvoie le fichier MP4 complet.
    private static func bestVariant(_ master: URL) async throws -> URL? {
        let (d, _) = try await URLSession.shared.data(from: master)
        let lines = String(decoding: d, as: UTF8.self).components(separatedBy: "\n")
        struct V { let side: Int; let bw: Int; let hevc: Bool; let uri: String }
        var vs: [V] = []
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF:") && i + 1 < lines.count {
            func attr(_ k: String) -> String? {
                guard let r = l.range(of: k + "=") else { return nil }
                var v = l[r.upperBound...]
                if v.hasPrefix("\"") { v = v.dropFirst(); return String(v.prefix { $0 != "\"" }) }
                return String(v.prefix { $0 != "," })
            }
            let side = Int(attr("RESOLUTION")?.split(separator: "x").first ?? "") ?? 0
            vs.append(V(side: side, bw: Int(attr("BANDWIDTH") ?? "") ?? 0, hevc: attr("CODECS")?.hasPrefix("hvc1") == true, uri: lines[i + 1]))
        }
        let ok = vs.filter { $0.side <= 1080 && $0.bw <= 7_000_000 }
        guard let pick = ok.max(by: { ($0.side, $0.hevc ? 1 : 0, $0.bw) < ($1.side, $1.hevc ? 1 : 0, $1.bw) }),
              let media = URL(string: pick.uri, relativeTo: master)?.absoluteURL else { return nil }
        // La playlist de la qualité pointe vers un seul fichier (plages d'octets) : on le prend en entier.
        let (md, _) = try await URLSession.shared.data(from: media)
        let mp4 = String(decoding: md, as: UTF8.self).components(separatedBy: "\n")
            .first { !$0.hasPrefix("#") && $0.hasSuffix(".mp4") }
        return mp4.flatMap { URL(string: $0, relativeTo: media)?.absoluteURL }
    }

    /// Garde le cache sous ~300 Mo (les plus anciennes vidéos partent en premier).
    private static func trimCache() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard var files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys) else { return }
        files.sort { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
            > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        var total = 0
        for f in files {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total > 300_000_000 { try? fm.removeItem(at: f) }
        }
    }

    private static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func stableHash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }
}

/// Lecteur en boucle, muet, partagé par toutes les fenêtres (un seul décodage vidéo).
final class MotionPlayer: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    func load(_ u: URL?) {
        guard u != url else { return }
        url = u
        player?.pause(); looper = nil
        guard let u else { player = nil; return }
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: u))
        player = p
    }

    /// Ne lit que lorsqu'on la voit (Mac verrouillé) : zéro coût le reste du temps.
    func setVisible(_ v: Bool) {
        guard let player else { return }
        if v { if player.rate == 0 { player.play() } } else if player.rate != 0 { player.pause() }
    }
}

struct MotionView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspectFill
        v.layer = l          // vue « hébergeant » la couche : layer d'abord, puis wantsLayer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let l = v.layer as? AVPlayerLayer, l.player !== player { l.player = player }
    }
}
