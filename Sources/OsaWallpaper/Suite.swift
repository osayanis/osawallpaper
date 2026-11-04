import AppKit
import Combine

// La suite Osa parle d'une appli à l'autre par notifications distribuées (même session,
// pas de serveur). Même protocole recopié dans OsaNotch (Suite.swift) :
//   com.osalabs.suite.hello      « je viens d'arriver » → les autres renvoient leur état
//   com.osalabs.suite.wallpaper  OsaWallpaper : volume / brightness (Bool) = ses pastilles s'en chargent
//   com.osalabs.suite.notch      OsaNotch : bottom (points sous le haut de l'écran à encoche), display
//   com.osalabs.suite.hub        OsaHUB : running (Bool). Tant qu'il tourne, notre icône de la barre des
//                                menus disparaît : nos options sont dans son menu.
//   com.osalabs.suite.wallpaperMenu    → OsaHUB : info ([String]), canPreview (Bool)
//   com.osalabs.suite.wallpaperAction  ← OsaHUB : action (open | preview | settings | quit)
enum Suite {
    static let hello = Notification.Name("com.osalabs.suite.hello")
    static let wallpaper = Notification.Name("com.osalabs.suite.wallpaper")
    static let notch = Notification.Name("com.osalabs.suite.notch")
    static let hub = Notification.Name("com.osalabs.suite.hub")
    static let wallpaperMenu = Notification.Name("com.osalabs.suite.wallpaperMenu")
    static let wallpaperAction = Notification.Name("com.osalabs.suite.wallpaperAction")

    static func post(_ name: Notification.Name, _ info: [String: Any] = [:]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }
}

/// Côté OsaWallpaper : annonce au notch que les pastilles son / luminosité sont les nôtres
/// (il n'affiche plus les siennes), et écoute où descend le notch pour passer dessous.
final class SuiteLink {
    private let prefs: Prefs
    private let target: ToastTarget
    private var bag = Set<AnyCancellable>()
    private var tokens: [NSObjectProtocol] = []
    /// OsaHUB tourne : il affiche nos options dans son menu, on cache notre icône.
    private(set) var hubPresent = false
    var onHub: ((Bool) -> Void)?
    var onAction: ((String) -> Void)?
    /// Ce qu'on montre dans le menu d'OsaHUB (météo, morceau, aperçu possible).
    var menuState: (() -> (info: [String], canPreview: Bool))?

    init(prefs: Prefs, target: ToastTarget) {
        self.prefs = prefs; self.target = target
    }

    func start() {
        let dc = DistributedNotificationCenter.default()
        tokens.append(dc.addObserver(forName: Suite.hello, object: nil, queue: .main) { [weak self] _ in self?.announce() })
        tokens.append(dc.addObserver(forName: Suite.notch, object: nil, queue: .main) { [weak self] n in
            guard let self, let bottom = n.userInfo?["bottom"] as? Double else { return }
            let display = CGDirectDisplayID((n.userInfo?["display"] as? Int) ?? 0)
            if self.target.notchDisplay != display { self.target.notchDisplay = display }
            if abs(self.target.notchBottom - bottom) > 0.5 { self.target.notchBottom = bottom }
        })
        // OsaHUB : arrivée / départ, et actions choisies dans son menu
        tokens.append(dc.addObserver(forName: Suite.hub, object: nil, queue: .main) { [weak self] n in
            self?.setHub(n.userInfo?["running"] as? Bool ?? false)
        })
        tokens.append(dc.addObserver(forName: Suite.wallpaperAction, object: nil, queue: .main) { [weak self] n in
            guard let self, self.hubPresent, let a = n.userInfo?["action"] as? String else { return }
            self.onAction?(a)
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.osalabs.osahub" else { return }
            self?.setHub(false)
        })
        // OsaNotch quitté : plus rien à éviter en haut de l'écran.
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.osalabs.osanotch" else { return }
            self?.target.notchBottom = 0
        })
        prefs.$showVolume.combineLatest(prefs.$showBrightness).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.announce() } }.store(in: &bag)
        announce()
        Suite.post(Suite.hello, ["app": "osawallpaper"])
    }

    private func setHub(_ on: Bool) {
        if on { publishMenu() }
        guard on != hubPresent else { return }
        hubPresent = on
        onHub?(on)
    }

    /// Envoie nos options à OsaHUB (à son arrivée, à l'ouverture de son menu, quand elles changent).
    func publishMenu() {
        guard let s = menuState?() else { return }
        Suite.post(Suite.wallpaperMenu, ["info": s.info, "canPreview": s.canPreview])
    }

    func announce() {
        Suite.post(Suite.wallpaper, ["volume": prefs.showVolume, "brightness": prefs.showBrightness])
    }

    /// À la fermeture : le notch reprend le son et la luminosité.
    func stop() {
        Suite.post(Suite.wallpaper, ["volume": false, "brightness": false])
    }
}
