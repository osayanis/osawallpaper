import AppKit
import ApplicationServices
import Collaboration
import os

// Où macOS dessine la connexion sur l'écran verrouillé (ta photo, ton nom, le champ du mot de
// passe), lue par l'Accessibilité. Sert aux fonds vidéo en plein écran : la vidéo couvre tout,
// OsaWallpaper redessine ta photo et ton nom à leur place exacte, et seul le champ du mot de passe
// reste ouvert sur macOS. Tant que macOS n'affiche pas la connexion (Mac inactif, économiseur
// d'écran), rien n'est ouvert : sinon on verrait ce que macOS montre dessous (l'économiseur…).
// Sans l'Accessibilité, ou si la connexion reste introuvable alors que tu touches le Mac, on
// ouvre une zone douce autour d'elle.
final class LoginUI: ObservableObject {
    static let shared = LoginUI()

    /// Coordonnées globales de l'Accessibilité (origine en haut à gauche de l'écran principal).
    struct Layout: Equatable { var avatar: CGRect?; var name: CGRect?; var field: CGRect? }
    @Published private(set) var layout: Layout?
    /// L'Accessibilité est autorisée : on sait quand la connexion est affichée.
    @Published private(set) var trusted = AXIsProcessTrusted()
    /// Tu touches le Mac depuis 3 s et la connexion reste introuvable : zone douce de secours.
    @Published private(set) var blind = false
    /// L'économiseur d'écran tourne sous l'écran verrouillé : notre fond doit tout couvrir.
    @Published private(set) var saver = false
    private var missingSince: Date?

    private init() {
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in self?.setSaver(true) }
        dn.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in self?.setSaver(false) }
    }

    private func setSaver(_ v: Bool) {
        guard saver != v else { return }
        saver = v
        log.notice("économiseur d'écran : \(v ? "lancé" : "arrêté", privacy: .public)")
    }

    private static func saverRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" || $0.localizedName == "ScreenSaverEngine"
        }
    }

    let fullName = NSFullUserName()
    lazy var picture: NSImage? = CBIdentity(name: NSUserName(), authority: .default())?.image

    private var timer: Timer?
    private var logged = false
    private let log = Logger(subsystem: "com.osalabs.osawallpaper", category: "login")

    /// Relu régulièrement : le champ du mot de passe peut n'apparaître qu'à la première touche.
    func start() {
        stop()
        logged = false
        trusted = AXIsProcessTrusted()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.scan() }
    }

    /// Tests visuels (mode démo) : une connexion placée comme celle de macOS.
    func demo(_ l: Layout) { layout = l }

    func stop() {
        timer?.invalidate(); timer = nil
        if layout != nil { layout = nil }
        if blind { blind = false }
        missingSince = nil
        setSaver(Self.saverRunning())
    }

    private func scan() {
        guard AXIsProcessTrusted() else {
            if !logged { log.notice("connexion : Accessibilité non autorisée, zone ouverte gardée"); logged = true }
            setSaver(Self.saverRunning())
            return
        }
        var found = Layout(), seen: [String] = [], texts: [CGRect] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow") {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            walk(root, depth: 0, &found, &seen, &texts)
        }
        // Le champ du mot de passe n'est souvent exposé que par son texte (« Saisir le mot de passe ») :
        // le texte large juste sous ton nom, centré sur lui. Sa vraie taille compte : une ouverture
        // plus petite que le champ laisse la vidéo mordre sur ses bords.
        if found.field == nil, let n = found.name {
            found.field = texts.filter { t in
                t.minY >= n.maxY - 2 && t.minY - n.maxY < 60 && abs(t.midX - n.midX) < 40
                    && (120...420).contains(t.width) && (18...60).contains(t.height)
            }.min { $0.minY < $1.minY }
        }
        if !logged { log.notice("connexion : \(seen.prefix(80).joined(separator: " | "), privacy: .public)"); logged = true }
        var l: Layout? = found.field == nil && found.avatar == nil && found.name == nil ? nil : found
        // macOS n'expose pas toujours la photo ni le champ : on les place d'après le nom, comme sur
        // l'écran natif (photo ronde au-dessus, champ du mot de passe en dessous).
        if let n = l?.name {
            if l?.avatar == nil { l?.avatar = CGRect(x: n.midX - 30, y: n.minY - 10 - 60, width: 60, height: 60) }
            if l?.field == nil { l?.field = CGRect(x: n.midX - 106, y: n.maxY + 12, width: 212, height: 32) }   // mesuré sur macOS 26
        }
        if l != layout {
            if found.name != nil || found.field != nil {
                log.notice("connexion, arbre : \(seen.prefix(120).joined(separator: " | "), privacy: .public)")
            }
            layout = l
            log.notice("connexion : photo \(String(describing: l?.avatar), privacy: .public) nom \(String(describing: l?.name), privacy: .public) champ \(String(describing: l?.field), privacy: .public)")
        }
        setSaver(Self.saverRunning() || (saver && l == nil))
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if l == nil && idle < 6 && !saver {
            let since = missingSince ?? Date()
            missingSince = since
            let b = Date().timeIntervalSince(since) >= 3
            if b != blind {
                blind = b
                if b { log.notice("connexion introuvable malgré l'activité : zone douce de secours") }
            }
        } else {
            missingSince = nil
            if blind { blind = false }
        }
    }

    private func walk(_ e: AXUIElement, depth: Int, _ f: inout Layout, _ seen: inout [String], _ texts: inout [CGRect]) {
        guard depth < 16 else { return }
        let role = Self.attr(e, kAXRoleAttribute) as? String ?? ""
        if let r = Self.frame(e), r.width > 2, r.height > 2 {
            seen.append("\(role) \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))")   // jamais les valeurs (mot de passe)
            switch role {
            case kAXTextFieldRole:
                if f.field == nil || r.width > f.field!.width { f.field = r }
            case kAXImageRole:
                // la photo de session : à peu près carrée, de taille raisonnable
                if abs(r.width - r.height) < 6, (32...220).contains(r.width), f.avatar == nil || r.width > f.avatar!.width { f.avatar = r }
            case kAXStaticTextRole:
                let v = Self.attr(e, kAXValueAttribute) as? String ?? ""
                if v == fullName || v == NSUserName() { f.name = r } else { texts.append(r) }
            default: break
            }
        }
        for c in Self.attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(c, depth: depth + 1, &f, &seen, &texts) }
    }

    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// Rectangle global de l'Accessibilité → coordonnées de la fenêtre de l'écran `screen` (origine en haut à gauche).
    static func local(_ r: CGRect, in screen: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.height
        return r.offsetBy(dx: -screen.minX, dy: -(primaryHeight - screen.maxY))
    }
}
