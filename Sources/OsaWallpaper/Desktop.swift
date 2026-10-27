import SwiftUI
import AppKit
import AVFoundation
import Combine
import os

// « Aussi sur le bureau » : le fond choisi devient celui du Mac déverrouillé.
// - Toujours : une image fixe devient le fond d'écran de macOS (photo, ou une image tirée de la
//   vidéo). Bonus : l'écran verrouillé de macOS montre ce même fond, le fondu du bas est parfait.
// - Vidéo « animée » : une fenêtre au niveau du bureau (sous les icônes, derrière toutes les
//   fenêtres) lit la vidéo en boucle, en pause dès que le Mac est verrouillé, en veille ou en
//   mode économie d'énergie.
// - « Plein écran » sur l'écran verrouillé pose aussi l'image fixe, mais seulement pendant que le Mac
//   est verrouillé : la zone laissée ouverte sur la connexion de macOS (photo, nom, mot de passe)
//   montre la même image, sans trou. Le fichier du fond affiché est noté au verrouillage et remis
//   tel quel au déverrouillage. La zone ne s'ouvre qu'une fois le fond de macOS changé (LockHole).
// Le fond d'origine de chaque écran est mémorisé et remis quand « Aussi sur le bureau » est coupé.
final class DesktopWallpaper {
    private let store: WallpaperStore
    private let prefs: Prefs
    private let lock: LockState
    private let player = MotionPlayer()                 // le sien : l'écran verrouillé a le sien
    private var windows: [NSWindow] = []
    private var filled = Set<Int>()                     // fenêtres qui affichent déjà la vidéo (windowNumber)
    private var bag = Set<AnyCancellable>()
    private var asleep = false
    private var applied: String?                        // fond posé sur le bureau (id + mode)
    private let log = Logger(subsystem: "com.osalabs.osawallpaper", category: "desktop")
    private static let originalsKey = "desktopOriginals"
    private static let lockKey = "lockOriginals"         // fond du bureau pendant un verrouillage (secours si l'app s'arrête)
    private var lockOriginals: [CGDirectDisplayID: URL] = [:]
    private var lockSwap = 0                             // numéro du verrouillage en cours (ignore les tâches d'un ancien)
    private var covers: [NSWindow] = []                  // le fond d'origine, peint au niveau du bureau pendant un verrouillage

    init(store: WallpaperStore, prefs: Prefs, lock: LockState) {
        self.store = store; self.prefs = prefs; self.lock = lock
        store.$current.map { $0?.id }.removeDuplicates()
            .combineLatest(prefs.$desktopToo, prefs.$desktopAnimated, prefs.$lockFullScreen)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
        lock.$locked.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] l in self?.lockChanged(l); self?.updatePlayback() }.store(in: &bag)
        if Demo.on { LockHole.shared.open = true }
        restoreAfterLock()                               // l'app s'était arrêtée pendant un verrouillage

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true; self?.updatePlayback() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = false; self?.updatePlayback() }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.updatePlayback() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.applied = nil; self?.apply() }
        }
    }

    private var animatedKind: Bool { store.current.map { $0.kind == .video || $0.kind == .youtube } ?? false }

    func apply() {
        guard prefs.desktopToo, let w = store.current else {
            removeWindows()
            restoreOriginals()
            applied = nil
            return
        }
        let animate = prefs.desktopToo && prefs.desktopAnimated && animatedKind
        let key = "\(w.id)|\(animate)"
        guard key != applied else { return }
        applied = key

        // 1) l'image fixe en fond d'écran de macOS (aussi sous la vidéo animée)
        Task { @MainActor [weak self] in
            guard let still = await Self.stillImage(for: w), self?.applied == key else { return }   // pas un fond déjà remplacé
            self?.setDesktopPicture(still)
        }
        // 2) la vidéo par-dessus, si animée
        removeWindows()
        if animate { makeWindows(for: w) }
        updatePlayback()
    }

    // MARK: Plein écran, Mac verrouillé

    func lockChanged(_ locked: Bool) {
        lockSwap += 1
        let n = lockSwap
        if locked && prefs.lockFullScreen && !Demo.on { LoginUI.shared.start() } else if !Demo.on { LoginUI.shared.stop() }
        guard locked else {
            LockHole.shared.open = Demo.on
            restoreAfterLock()
            // macOS remet son fond sous le cache, en fondu, mais il est lent juste après un
            // déverrouillage : on attend largement qu'il ait fini avant d'effacer le cache, doucement.
            let c = covers
            covers = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 1.2
                    c.forEach { $0.animator().alphaValue = 0 }
                }, completionHandler: { c.forEach { $0.orderOut(nil); $0.close() } })
            }
            return
        }
        guard prefs.lockFullScreen, !prefs.desktopToo, !Demo.on, let w = store.current else {
            LockHole.shared.open = true                  // bureau déjà sur notre fond, ou rien à faire
            return
        }
        // Seulement si on sait remettre exactement le fond affiché (une image) au déverrouillage.
        var originals: [CGDirectDisplayID: URL] = [:]
        for s in NSScreen.screens {
            guard let u = NSWorkspace.shared.desktopImageURL(for: s), Self.plainImage(u),
                  !u.path.hasPrefix(WallpaperStore.dir.path), let file = Self.existing(u.path) else {
                log.notice("verrouillage : fond actuel non remplaçable (\(NSWorkspace.shared.desktopImageURL(for: s)?.path ?? "aucun", privacy: .public))")
                LockHole.shared.open = true
                return
            }
            originals[s.displayID] = file
        }
        LockHole.shared.open = false
        lockOriginals = originals
        showCovers(originals)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: originals.map { (String($0.key), $0.value.path) }), forKey: Self.lockKey)
        Task { @MainActor [weak self] in
            guard let still = await Self.stillImage(for: w), let self, self.lockSwap == n else { return }
            for s in NSScreen.screens {
                do { try NSWorkspace.shared.setDesktopImageURL(still, for: s, options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]) }
                catch { self.log.error("verrouillage : \(error.localizedDescription, privacy: .public)") }
            }
            self.log.notice("verrouillage : fond macOS → \(still.lastPathComponent, privacy: .public), à remettre : \(originals.values.map(\.lastPathComponent), privacy: .public)")
            // Le temps que macOS affiche le nouveau fond, puis la zone de connexion s'ouvre.
            try? await Task.sleep(for: .seconds(1.2))
            guard self.lockSwap == n else { return }
            withAnimation(.easeInOut(duration: 0.6)) { LockHole.shared.open = true }
        }
    }

    /// Le fond d'origine peint au niveau du bureau (sous les icônes et les fenêtres), le temps du
    /// verrouillage : invisible derrière l'écran verrouillé, il est là dès le déverrouillage, avant
    /// même que macOS ait remis son fond. Pas d'aller-retour visible avec notre fond.
    private func showCovers(_ originals: [CGDirectDisplayID: URL]) {
        covers.forEach { $0.orderOut(nil); $0.close() }
        covers = NSScreen.screens.compactMap { s in
            guard let u = originals[s.displayID], let img = NSImage(contentsOf: u) else { return nil }
            let win = NSWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.ignoresMouseEvents = true
            win.isReleasedWhenClosed = false
            win.hasShadow = false
            win.backgroundColor = .black
            let v = NSView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.wantsLayer = true
            v.layer?.contents = img
            v.layer?.contentsGravity = .resizeAspectFill      // comme macOS : « Remplir l'écran »
            win.contentView = v
            win.setFrame(s.frame, display: true)
            win.orderFrontRegardless()
            return win
        }
    }

    /// Remet le fond noté au verrouillage (en mémoire, ou dans les réglages si l'app s'est arrêtée).
    private func restoreAfterLock() {
        var originals = lockOriginals
        if originals.isEmpty, let saved = UserDefaults.standard.dictionary(forKey: Self.lockKey) as? [String: String] {
            for (k, p) in saved { if let id = CGDirectDisplayID(k), let u = Self.existing(p) { originals[id] = u } }
        }
        lockOriginals = [:]
        UserDefaults.standard.removeObject(forKey: Self.lockKey)
        guard !originals.isEmpty, !prefs.desktopToo, Self.oursOnScreen() else { return }
        for s in NSScreen.screens {
            guard let u = originals[s.displayID] ?? originals.values.first else { continue }
            do { try NSWorkspace.shared.setDesktopImageURL(u, for: s, options: [:]) }
            catch { log.error("déverrouillage : \(error.localizedDescription, privacy: .public)") }
        }
        log.notice("déverrouillage : fond remis → \(originals.values.map(\.lastPathComponent), privacy: .public)")
    }

    // MARK: Image fixe

    /// Photo : le fichier. Vidéo : une image tirée de la vidéo, en pleine qualité. YouTube : la miniature HD.
    static func stillImage(for w: Wallpaper) async -> URL? {
        let base = w.id.replacingOccurrences(of: "/", with: "-")
        let out = WallpaperStore.dir.appendingPathComponent(base + (w.kind == .video ? "-still.png" : "-desktop.jpg"))
        switch w.kind {
        case .image:
            return w.localURL
        case .video:
            if FileManager.default.fileExists(atPath: out.path) { return out }
            guard let f = w.localURL else { return nil }
            // L'image exacte (pas l'image clé la plus proche, souvent plus floue), en taille réelle,
            // enregistrée sans perte : pas de différence visible avec la vidéo qui tourne.
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: f))
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            g.maximumSize = .zero
            guard let cg = try? await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
            return (try? png.write(to: out)) != nil ? out : nil
        case .youtube:
            if FileManager.default.fileExists(atPath: out.path) { return out }
            guard let id = w.youtubeID else { return nil }
            for q in ["maxresdefault", "sddefault", "hqdefault"] {
                if let u = URL(string: "https://i.ytimg.com/vi/\(id)/\(q).jpg"),
                   let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200 {
                    return (try? d.write(to: out)) != nil ? out : nil
                }
            }
            return nil
        }
    }

    private func setDesktopPicture(_ url: URL) {
        guard !Demo.on else { return }      // les tests ne touchent jamais au vrai fond d'écran
        saveOriginals()
        let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true,
        ]
        for s in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: s, options: opts) }
            catch { log.error("fond du bureau : \(error.localizedDescription, privacy: .public)") }
        }
    }

    // Le fond d'origine : toute la configuration de macOS (fonds animés, dynamiques, couleurs,
    // un fond par bureau…) copiée avant notre premier changement, puis remise telle quelle.
    // En secours, l'image de chaque écran (si la copie manque).
    private static let appleStore = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    private static let backup = WallpaperStore.dir.deletingLastPathComponent().appendingPathComponent("desktop-original.plist")

    /// Mémorise le fond d'origine, une seule fois (avant notre premier changement).
    private func saveOriginals() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.backup.path), !Self.oursOnScreen() {
            do { try fm.copyItem(at: Self.appleStore, to: Self.backup) }
            catch { log.error("copie du fond d'origine : \(error.localizedDescription, privacy: .public)") }
        }
        let d = UserDefaults.standard
        var saved = d.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        var changed = false
        for s in NSScreen.screens where saved[String(s.displayID)] == nil {
            if let u = NSWorkspace.shared.desktopImageURL(for: s), !u.path.hasPrefix(WallpaperStore.dir.path) {
                saved[String(s.displayID)] = u.path; changed = true
            }
        }
        if changed { d.set(saved, forKey: Self.originalsKey) }
    }

    /// Un de nos fonds est-il affiché sur un écran ?
    private static func oursOnScreen() -> Bool {
        NSScreen.screens.contains { NSWorkspace.shared.desktopImageURL(for: $0)?.path.hasPrefix(WallpaperStore.dir.path) == true }
    }

    private func restoreOriginals() {
        guard !Demo.on else { return }
        let fm = FileManager.default
        let saved = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String]
        defer {
            try? fm.removeItem(at: Self.backup)
            UserDefaults.standard.removeObject(forKey: Self.originalsKey)
        }
        // Si l'utilisateur a choisi un autre fond entre-temps, on n'y touche pas.
        guard Self.oursOnScreen() else { return }
        let hasBackup = fm.fileExists(atPath: Self.backup.path)
        let urls = NSScreen.screens.map { s in saved?[String(s.displayID)].flatMap(Self.existing) }
        // Simples images : remise douce par macOS (fondu), sans relancer WallpaperAgent.
        // Sinon (fond animé, dynamique…) : la configuration copiée, remise telle quelle.
        let plain = NSScreen.screens.allSatisfy { s in saved?[String(s.displayID)].map { Self.plainImage(URL(fileURLWithPath: $0)) } ?? false }
        if plain, !urls.contains(where: { $0 == nil }) {
            for (s, u) in zip(NSScreen.screens, urls) {
                guard let u else { continue }
                do { try NSWorkspace.shared.setDesktopImageURL(u, for: s, options: [:]) }
                catch { log.error("fond d'origine : \(error.localizedDescription, privacy: .public)") }
            }
        } else if hasBackup {
            _ = restoreAppleStore()
        }
    }

    /// Le fichier d'un fond d'origine, s'il existe encore. macOS peut afficher un fond dont le fichier
    /// a disparu (il en garde une copie en cache) : jamais de fichier « qui y ressemble » à la place
    /// (un même nom en .jpg peut être une tout autre image). Dans ce cas, la configuration copiée.
    private static func existing(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Une simple image choisie par l'utilisateur ? Les fonds de macOS (dynamiques, animés, aux
    /// vignettes rangées dans le système ou les caches) passent par la configuration copiée.
    private static func plainImage(_ u: URL) -> Bool {
        let p = u.path
        return ["jpg", "jpeg", "png", "heic", "avif", "webp", "tiff"].contains(u.pathExtension.lowercased())
            && !p.hasPrefix("/System/") && !p.contains("/com.apple.wallpaper/") && !p.contains("/Caches/")
    }

    /// Remet la configuration copiée et relance WallpaperAgent (le service de macOS qui affiche
    /// les fonds) pour qu'il la relise.
    private func restoreAppleStore() -> Bool {
        do {
            try Self.replace(Self.appleStore, with: Self.backup)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["WallpaperAgent"]
            try p.run(); p.waitUntilExit()
            return true
        } catch {
            log.error("remise du fond d'origine : \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func replace(_ dst: URL, with src: URL) throws {
        let tmp = dst.deletingLastPathComponent().appendingPathComponent("Index.osawallpaper.plist")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: src, to: tmp)
        _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
    }

    // MARK: Vidéo animée

    private func makeWindows(for w: Wallpaper) {
        if w.kind == .video { player.load(w.localURL) }
        for s in NSScreen.screens {
            let win = NSWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            // Juste au-dessus de l'image du bureau, sous les icônes et toutes les fenêtres.
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.ignoresMouseEvents = true
            win.isReleasedWhenClosed = false
            win.hasShadow = false
            win.backgroundColor = .black
            win.setFrame(s.frame, display: false)
            windows.append(win)
        }
        updatePlayback()
    }

    private func removeWindows() {
        windows.forEach { $0.orderOut(nil); $0.contentView = NSView(); $0.close() }
        windows = []
        filled = []
        player.setVisible(false)
        player.load(nil)
    }

    /// Lecture seulement quand on peut la voir : pas verrouillé, écran allumé, pas en économie d'énergie.
    private func updatePlayback() {
        guard !windows.isEmpty, let w = store.current else { return }
        let run = !lock.locked && !asleep && !ProcessInfo.processInfo.isLowPowerModeEnabled
        for win in windows {
            let size = win.frame.size
            switch w.kind {
            case .video:
                if !filled.contains(win.windowNumber), let p = player.player {
                    win.contentView = NSHostingView(rootView: MotionView(player: p).frame(width: size.width, height: size.height))
                    filled.insert(win.windowNumber)
                }
            case .youtube:
                // Le lecteur YouTube n'a pas de pause : on le retire quand il ne doit pas tourner.
                if run, !filled.contains(win.windowNumber), let id = w.youtubeID {
                    win.contentView = NSHostingView(rootView: YouTubeView(id: id).frame(width: size.width, height: size.height))
                    filled.insert(win.windowNumber)
                } else if !run, filled.contains(win.windowNumber) {
                    win.contentView = NSView()          // détruit le lecteur : plus de réseau ni de CPU
                    filled.remove(win.windowNumber)
                }
            case .image:
                break
            }
            if run { win.orderFrontRegardless() } else if w.kind == .youtube { win.orderOut(nil) }
        }
        if w.kind == .video { player.setVisible(run) }
    }
}
