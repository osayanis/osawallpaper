import AppKit
import QuartzCore

// La mascotte dans la barre des menus : elle tourne doucement sur elle-même. Les images d'un tour
// sont dessinées une fois pour toutes, puis Core Animation les fait défiler sur un calque du
// bouton : l'app ne fait rien à chaque image (changer l'image du bouton 20 fois par seconde
// coûtait ~14 % de CPU). Couleur suivant la barre des menus (claire ou sombre) ; arrêtée quand
// l'écran dort ou que la session n'est plus affichée.
final class MenuMascot {
    private weak var button: NSStatusBarButton?
    private let host = NSView()
    private var observation: NSKeyValueObservation?
    private var dark: Bool?
    private static let count = 64, turn = 3.2, size: CGFloat = 18     // un tour en 3,2 s

    init(button: NSStatusBarButton) {
        self.button = button
        button.image = NSImage(size: NSSize(width: Self.size, height: Self.size))   // la place ; le calque dessine
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "OsaWallpaper"
        button.setAccessibilityLabel("OsaWallpaper")

        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            host.widthAnchor.constraint(equalToConstant: Self.size),
            host.heightAnchor.constraint(equalToConstant: Self.size),
        ])
        observation = button.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.start() }
        }

        let ws = NSWorkspace.shared.notificationCenter
        for (name, run) in [(NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
                            (NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in run ? self?.start() : self?.stop() }
        }
    }

    /// (Re)lance le tour, aux couleurs de la barre des menus.
    func start() {
        guard let button, let layer = host.layer else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark == isDark, layer.animation(forKey: "tour") != nil { return }
        dark = isDark
        let scale = button.window?.backingScaleFactor ?? 2
        let images: [CGImage] = (0..<Self.count).compactMap { i in
            Self.tinted(Self.frame(angle: Double(i) / Double(Self.count) * 2 * .pi), color: isDark ? .white : .black, scale: scale)
        }
        guard images.count == Self.count else { return }
        layer.contentsScale = scale
        layer.contentsGravity = .resizeAspect
        layer.contents = images[0]
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = images
        a.calculationMode = .discrete
        a.duration = Self.turn
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "tour")
    }

    func stop() { host.layer?.removeAnimation(forKey: "tour") }

    private static func tinted(_ img: NSImage, color: NSColor, scale: CGFloat) -> CGImage? {
        let px = Int(size * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let r = NSRect(x: 0, y: 0, width: px, height: px)
        img.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// La mascotte (mêmes proportions que sur le site OsaLabs) vue sous l'angle `angle` autour de son
    /// axe vertical : de face, son visage est découpé dans la silhouette ; de dos, elle est pleine.
    static func frame(angle: Double, size: CGFloat = MenuMascot.size) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGFloat(cos(angle))
            let s = size / 84                           // le corps (84 × 80) occupe toute la hauteur utile
            let bw = 84 * s, bh = 80 * s
            ctx.translateBy(x: size / 2, y: (size - bh) / 2)
            ctx.scaleBy(x: max(abs(c), 0.07), y: 1)    // la rotation, vue de face
            ctx.translateBy(x: -bw / 2, y: 0)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bw, height: bh), xRadius: 38 * s, yRadius: 37 * s).fill()
            guard c > 0.15 else { return true }         // de dos (ou de profil) : pas de visage
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for x in [25.0, 59.0] {                     // les yeux
                NSBezierPath(roundedRect: NSRect(x: (x - 8.5) * s, y: (36 - 12) * s, width: 17 * s, height: 24 * s),
                             xRadius: 8.5 * s, yRadius: 8.5 * s).fill()
            }
            let smile = NSBezierPath()                  // le sourire
            smile.move(to: NSPoint(x: 34 * s, y: 54 * s))
            smile.curve(to: NSPoint(x: 50 * s, y: 54 * s), controlPoint1: NSPoint(x: 38 * s, y: 62 * s), controlPoint2: NSPoint(x: 46 * s, y: 62 * s))
            smile.lineWidth = 6.5 * s
            smile.lineCapStyle = .round
            smile.stroke()
            return true
        }
    }
}
