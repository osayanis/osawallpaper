import SwiftUI
import AppKit
import CoreImage

// Musique en cours (Music / Spotify) — même moteur qu'OsaNotch :
// osascript en sous-processus, file série, timeout, jamais deux appels à la fois.
struct MusicInfo: Equatable {
    var playing: Bool; var title: String; var artist: String; var album: String; var source: String
    var position: Double; var duration: Double; var favorite: Bool?
}
struct LyricLine: Equatable { var t: Double; var text: String }

final class MusicWatcher: ObservableObject {
    @Published var music: MusicInfo?
    @Published var artwork: NSImage?
    @Published var backdrop: NSImage?          // pochette floutée pour le fond d'écran
    @Published var palette: [Color] = []       // 9 couleurs (grille 3×3) tirées de la pochette → dégradé animé
    @Published var accent: Color = Color(red: 0.62, green: 0.75, blue: 1.0)
    @Published var lyrics: [LyricLine] = []
    @Published var sampledAt = Date()          // instant de lecture de `position` → interpolation

    private let q = DispatchQueue(label: "osa.music", qos: .utility)
    private var busy = false
    private var key = ""
    private var timer: Timer?

    func start() {
        if let demo = ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO"] { startDemo(artPath: demo); return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Mode démo (tests visuels) : un faux morceau, sans toucher aux apps de musique.
    private func startDemo(artPath: String) {
        music = MusicInfo(playing: true, title: "Nuit d’été", artist: "Les Osa", album: "Démo", source: "Music",
                          position: 61, duration: 168, favorite: false)
        sampledAt = Date()
        lyrics = (0..<40).map { LyricLine(t: 55 + Double($0) * 3, text: ["Et la nuit ne finit jamais", "On danse sous les étoiles", "La mer nous appelle encore"][$0 % 3]) }
        if let img = NSImage(contentsOfFile: artPath) {
            artwork = img; backdrop = Self.blurred(img); palette = Self.palette(img)
            if let c = Self.vibrantColor(img) { accent = c }
        }
    }

    /// Position estimée maintenant (la lecture n'est faite que toutes les 1,5 s).
    func position(at date: Date) -> Double {
        guard let m = music else { return 0 }
        let p = m.playing ? m.position + date.timeIntervalSince(sampledAt) : m.position
        return min(max(0, p), max(m.duration, 0))
    }

    func poll() {
        if busy { return }
        busy = true
        q.async {
            defer { self.busy = false }
            let out = Shell.osa(Self.script(), timeout: 4)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let out, !out.isEmpty, out != "none" else {
                DispatchQueue.main.async {
                    if self.music != nil { self.music = nil; self.artwork = nil; self.backdrop = nil; self.palette = []; self.lyrics = [] }
                    self.key = ""
                }
                return
            }
            let p = out.components(separatedBy: "||")
            guard p.count >= 8 else { return }
            // AppleScript écrit les décimales avec une virgule en locale FR.
            func num(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0 }
            let fav: Bool? = p[7] == "true" ? true : p[7] == "false" ? false : nil
            let info = MusicInfo(playing: p[0] == "playing", title: p[1], artist: p[2], album: p[3], source: p[4],
                                 position: num(p[5]), duration: num(p[6]), favorite: fav)
            let art = p.count > 8 ? p[8] : ""
            let k = "\(info.artist)|\(info.title)"
            DispatchQueue.main.async {
                // On ne republie que si quelque chose a vraiment changé : la position
                // est interpolée localement, inutile de tout redessiner toutes les 1,5 s.
                let drift = abs(self.position(at: Date()) - info.position)
                if let old = self.music, old.title == info.title, old.artist == info.artist, old.playing == info.playing,
                   old.favorite == info.favorite, old.duration == info.duration, drift < 1.5 {
                } else {
                    self.music = info; self.sampledAt = Date()
                }
                if k != self.key {
                    self.key = k
                    self.lyrics = []
                    self.loadArtwork(k, art: art, artist: info.artist, title: info.title, album: info.album)
                    self.fetchLyrics(k, artist: info.artist, title: info.title, duration: info.duration)
                }
            }
        }
    }

    // MARK: Contrôles
    func control(_ verb: String) {
        if ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO"] != nil {
            if verb == "playpause", var m = music { m.position = position(at: Date()); m.playing.toggle(); music = m; sampledAt = Date() }
            return
        }
        guard let src = music?.source else { return }
        let app = src == "Spotify" ? "Spotify" : "Music"
        let script = "tell application \"\(app)\" to \(verb)"
        q.async { _ = Shell.osa(script, timeout: 4); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.poll() } }
        if verb == "playpause", var m = music { m.playing.toggle(); m.position = position(at: Date()); music = m; sampledAt = Date() }
    }
    func toggleFavorite() {
        guard music?.source == "Music", let fav = music?.favorite else { return }
        music?.favorite = !fav
        let script = """
        tell application "Music"
          try
            set favorited of current track to \(!fav)
          on error
            try
              set loved of current track to \(!fav)
            end try
          end try
        end tell
        """
        q.async { _ = Shell.osa(script, timeout: 4) }
    }

    // MARK: Pochette (fichier local de Music, URL Spotify, sinon recherche iTunes)
    private func loadArtwork(_ k: String, art: String, artist: String, title: String, album: String) {
        artwork = nil
        let apply: (NSImage) -> Void = { img in
            let col = Self.vibrantColor(img)
            let blur = Self.blurred(img)
            let pal = Self.palette(img)
            DispatchQueue.main.async {
                guard self.key == k else { return }
                withAnimation(.easeInOut(duration: 0.8)) {
                    self.artwork = img; self.backdrop = blur; self.palette = pal
                    if let col { self.accent = col }
                }
            }
        }
        q.async {
            if art.hasPrefix("local:"), let img = NSImage(contentsOf: URL(fileURLWithPath: String(art.dropFirst(6)))) {
                apply(img); return
            }
            if art.hasPrefix("http"), let u = URL(string: art), let img = NSImage(contentsOf: u) { apply(img); return }
            self.searchArtwork(k, artist: artist, title: title, album: album, apply: apply)
        }
    }

    private func searchArtwork(_ k: String, artist: String, title: String, album: String, apply: @escaping (NSImage) -> Void) {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "" }
        let queries = [
            "https://itunes.apple.com/search?term=\(enc("\(artist) \(title)"))&entity=song&limit=1",
            "https://itunes.apple.com/search?term=\(enc("\(artist) \(album)"))&entity=album&limit=1",
            "https://itunes.apple.com/search?term=\(enc(title))&entity=song&limit=1",
        ]
        for q in queries {
            guard let u = URL(string: q), let data = try? Data(contentsOf: u),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = (j["results"] as? [[String: Any]])?.first,
                  let small = r["artworkUrl100"] as? String,
                  let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")),
                  let img = NSImage(contentsOf: big) else { continue }
            apply(img); return
        }
    }

    // MARK: Paroles synchronisées (LRCLIB)
    private func fetchLyrics(_ k: String, artist: String, title: String, duration: Double) {
        func enc(_ s: String) -> String {
            var a = CharacterSet.urlQueryAllowed; a.remove(charactersIn: "&+=")
            return s.addingPercentEncoding(withAllowedCharacters: a) ?? ""
        }
        func req(_ s: String) -> URLRequest {
            var r = URLRequest(url: URL(string: s)!)
            r.setValue("OsaWallpaper (https://osalabs.fr)", forHTTPHeaderField: "User-Agent")
            return r
        }
        let set: (String) -> Void = { synced in
            let lines = Self.parseLRC(synced)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { if self.key == k { self.lyrics = lines } }
        }
        let get = "https://lrclib.net/api/get?artist_name=\(enc(artist))&track_name=\(enc(title))&duration=\(Int(duration.rounded()))"
        let search = "https://lrclib.net/api/search?track_name=\(enc(title))&artist_name=\(enc(artist))"
        URLSession.shared.dataTask(with: req(get)) { data, _, _ in
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let s = j["syncedLyrics"] as? String, !s.isEmpty { set(s); return }
            URLSession.shared.dataTask(with: req(search)) { data, _, _ in
                guard let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let s = arr.compactMap({ $0["syncedLyrics"] as? String }).first(where: { !$0.isEmpty }) else { return }
                set(s)
            }.resume()
        }.resume()
    }

    static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for line in raw.components(separatedBy: .newlines) {
            guard let close = line.firstIndex(of: "]") else { continue }
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            var rest = Substring(line)
            while let o = rest.firstIndex(of: "["), let e = rest.firstIndex(of: "]"), o < e {
                let c = rest[rest.index(after: o)..<e].split(separator: ":")
                if c.count == 2, let m = Double(c[0]), let s = Double(c[1]) { out.append(LyricLine(t: m * 60 + s, text: text)) }
                rest = rest[rest.index(after: e)...]
            }
        }
        return out.filter { !$0.text.isEmpty }.sorted { $0.t < $1.t }
    }

    // MARK: Script AppleScript
    // Ne cite une app que si elle est installée (sinon macOS demande « Où est … ? » en boucle).
    static let hasMusic = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil
    static let hasSpotify = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil

    static func script() -> String {
        var s = "set out to \"none\"\n"
        if hasMusic {
            s += """
            if (running of application "Music") then
              tell application "Music"
                try
                  if player state is not stopped then
                    set pos to 0
                    set dur to 0
                    set fav to "?"
                    set artFlag to ""
                    set alb to ""
                    try
                      set pos to player position
                      set dur to duration of current track
                      set alb to album of current track
                    end try
                    try
                      set fav to (favorited of current track) as string
                    on error
                      try
                        set fav to (loved of current track) as string
                      end try
                    end try
                    try
                      if exists (artwork 1 of current track) then
                        set artData to raw data of artwork 1 of current track
                        set f to open for access (POSIX file "/tmp/osawallpaper_art") with write permission
                        set eof of f to 0
                        write artData to f
                        close access f
                        set artFlag to "local:/tmp/osawallpaper_art"
                      end if
                    end try
                    set out to (player state as string) & "||" & (name of current track) & "||" & (artist of current track) & "||" & alb & "||Music||" & pos & "||" & dur & "||" & fav & "||" & artFlag
                  end if
                end try
              end tell
            end if

            """
        }
        if hasSpotify {
            s += """
            if out is "none" and (running of application "Spotify") then
              tell application "Spotify"
                try
                  set pos to 0
                  set dur to 0
                  set artUrl to ""
                  try
                    set pos to player position
                    set dur to (duration of current track) / 1000
                    set artUrl to artwork url of current track
                  end try
                  set out to (player state as string) & "||" & (name of current track) & "||" & (artist of current track) & "||" & (album of current track) & "||Spotify||" & pos & "||" & dur & "||?||" & artUrl
                end try
              end tell
            end if

            """
        }
        return s + "return out"
    }

    // MARK: Image
    static func vibrantColor(_ img: NSImage) -> Color? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        var best: (Double, Double, Double)?; var score = -1.0
        for x in stride(from: 0, to: w, by: max(1, w / 18)) {
            for y in stride(from: 0, to: h, by: max(1, h / 18)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx == 0 ? 0 : (mx - mn) / mx
                if sat * mx > score && mx > 0.3 { score = sat * mx; best = (r, g, b) }
            }
        }
        guard let b = best else { return nil }
        // Éclaircie : la couleur sert de teinte sur fond sombre.
        return Color(red: 0.45 + b.0 * 0.55, green: 0.45 + b.1 * 0.55, blue: 0.45 + b.2 * 0.55)
    }

    /// Les couleurs de la pochette sur une grille 3×3 (réduction à 3×3 pixels),
    /// plus saturées et assombries en haut pour garder l'horloge lisible.
    static func palette(_ img: NSImage) -> [Color] {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 3, height: 3))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var out: [Color] = []
        for row in 0..<3 {            // la ligne 0 du tampon = le haut de l'image
            for col in 0..<3 {
                let i = (row * 3 + col) * 4
                let c = NSColor(srgbRed: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255, blue: CGFloat(px[i + 2]) / 255, alpha: 1)
                var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
                let dark: CGFloat = row == 0 ? 0.7 : row == 1 ? 0.85 : 0.75
                // léger décalage de teinte d'une case à l'autre : du relief même sur une pochette unie
                let shift = CGFloat(col - 1) * 0.035 + CGFloat(row - 1) * 0.02
                let hue = (h + shift).truncatingRemainder(dividingBy: 1) + (h + shift < 0 ? 1 : 0)
                out.append(Color(hue: hue, saturation: min(1, sat * 1.35 + 0.08), brightness: min(0.9, max(0.14, b * dark))))
            }
        }
        return out
    }

    /// Pochette très floutée et légèrement assombrie, calculée une seule fois par morceau.
    static func blurred(_ img: NSImage) -> NSImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let src = CIImage(cgImage: cg)
        let side = 640.0
        let scale = side / max(src.extent.width, src.extent.height)
        let small = src.transformed(by: .init(scaleX: scale, y: scale))
        let out = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 24)
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.25, "inputBrightness": -0.06])
            .cropped(to: small.extent)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let res = ctx.createCGImage(out, from: small.extent) else { return nil }
        return NSImage(cgImage: res, size: NSSize(width: small.extent.width, height: small.extent.height))
    }
}

enum Shell {
    static func run(_ launch: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Lecture en parallèle : une sortie > 64 Ko bloquerait sinon le processus.
        var data = Data()
        let g = DispatchGroup(); g.enter()
        DispatchQueue.global(qos: .utility).async { data = pipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        if g.wait(timeout: .now() + timeout) == .timedOut { kill(p.processIdentifier, SIGKILL); return nil }
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    static func osa(_ script: String, timeout: TimeInterval) -> String? { run("/usr/bin/osascript", ["-e", script], timeout: timeout) }
}
