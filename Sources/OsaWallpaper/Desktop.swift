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
// Le fond d'origine de chaque écran est mémorisé et remis quand l'option est coupée.
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

    init(store: WallpaperStore, prefs: Prefs, lock: LockState) {
        self.store = store; self.prefs = prefs; self.lock = lock
        store.$current.map { $0?.id }.removeDuplicates()
            .combineLatest(prefs.$desktopToo, prefs.$desktopAnimated)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
        lock.$locked.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.updatePlayback() }.store(in: &bag)

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
        let animate = prefs.desktopAnimated && animatedKind
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

    // MARK: Image fixe

    /// Photo : le fichier. Vidéo : une image tirée de la vidéo. YouTube : la miniature HD.
    static func stillImage(for w: Wallpaper) async -> URL? {
        let out = WallpaperStore.dir.appendingPathComponent(w.id.replacingOccurrences(of: "/", with: "-") + "-desktop.jpg")
        switch w.kind {
        case .image:
            return w.localURL
        case .video:
            if FileManager.default.fileExists(atPath: out.path) { return out }
            guard let f = w.localURL else { return nil }
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: f))
            g.appliesPreferredTrackTransform = true
            guard let cg = try? await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image,
                  let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
            return (try? jpg.write(to: out)) != nil ? out : nil
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

    /// Mémorise le fond d'origine de chaque écran, une seule fois (avant notre premier changement).
    private func saveOriginals() {
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

    private func restoreOriginals() {
        guard !Demo.on, let saved = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] else { return }
        for s in NSScreen.screens {
            if let p = saved[String(s.displayID)], FileManager.default.fileExists(atPath: p) {
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: p), for: s, options: [:])
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.originalsKey)
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
