import AppKit
import QuartzCore

// La mascotte dans la barre des menus : elle se promène en rond, en 3D. Elle marche sur un cercle
// vu de face (plus grande et plus bas quand elle passe devant, plus petite au fond), se tourne dans
// le sens de sa marche (son visage glisse autour de son corps, on voit son dos quand elle s'éloigne)
// et pose un pied après l'autre. Les images d'un tour sont dessinées une fois pour toutes, puis
// Core Animation les fait défiler sur un calque du bouton : l'app ne fait rien à chaque image
// (changer l'image du bouton 20 fois par seconde coûtait ~14 % de CPU). Arrêtée quand l'écran dort
// ou que la session n'est plus affichée.
final class MenuMascot {
    private weak var button: NSStatusBarButton?
    private let host = NSView()
    private var scale: CGFloat = 0
    private static let count = 100, loop = 5.0           // un tour de piste en 5 s
    private static let size = CGSize(width: 30, height: 22)

    init(button: NSStatusBarButton) {
        self.button = button
        button.image = NSImage(size: Self.size)             // la place ; le calque dessine
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
            host.widthAnchor.constraint(equalToConstant: Self.size.width),
            host.heightAnchor.constraint(equalToConstant: Self.size.height),
        ])

        let ws = NSWorkspace.shared.notificationCenter
        for (name, run) in [(NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
                            (NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in run ? self?.start() : self?.stop() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: nil, queue: .main) { [weak self] n in
            if (n.object as? NSWindow) === self?.button?.window { self?.start() }
        }
        DispatchQueue.main.async { self.start() }
    }

    func start() {
        guard let button, let layer = host.layer else { return }
        let sc = button.window?.backingScaleFactor ?? 2
        if sc == scale, layer.animation(forKey: "tour") != nil { return }
        scale = sc
        let images = (0..<Self.count).compactMap { Self.frame(Double($0) / Double(Self.count), scale: sc) }
        guard images.count == Self.count else { return }
        layer.contentsScale = sc
        layer.contentsGravity = .resizeAspect
        layer.contents = images[0]
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = images
        a.calculationMode = .discrete
        a.duration = Self.loop
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "tour")
    }

    func stop() { host.layer?.removeAnimation(forKey: "tour"); scale = 0 }

    // Couleurs de la mascotte du site OsaLabs.
    private static let ink = CGColor(red: 0.106, green: 0.114, blue: 0.141, alpha: 1)
    private static let light = CGColor(red: 0.995, green: 0.99, blue: 0.97, alpha: 1)
    private static let shade = CGColor(red: 0.84, green: 0.81, blue: 0.76, alpha: 1)
    private static let feet = CGColor(red: 0.62, green: 0.59, blue: 0.55, alpha: 1)
    private static let cheek = CGColor(red: 1, green: 0.5, blue: 0.59, alpha: 0.55)

    /// L'image à l'instant `t` du tour (0…1).
    static func frame(_ t: Double, scale sc: CGFloat) -> CGImage? {
        let W = size.width, H = size.height
        guard let ctx = CGContext(data: nil, width: Int(W * sc), height: Int(H * sc), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: sc, y: -sc); ctx.translateBy(x: 0, y: -H)    // en points, y vers le bas

        let θ = 2 * Double.pi * t
        let z = CGFloat(cos(θ))                             // 1 : devant, -1 : au fond
        let near = (z + 1) / 2
        let k = 0.8 + 0.2 * near                            // perspective
        let cx = W / 2 + 7.5 * CGFloat(sin(θ))
        let ground = H - 2.2 - 3 * (1 - near)
        // Sens de la marche (0 : vers nous, > 0 : vers la droite de l'écran).
        let φ = atan2(cos(θ), -sin(θ))
        let step = 2 * Double.pi * 7 * t                    // 7 pas par tour
        let bob = CGFloat(abs(sin(step))) * 0.9 * k

        let bw = 14.2 * k, bh = 13.5 * k
        let body = CGRect(x: cx - bw / 2, y: ground - 1.6 * k - bh - bob, width: bw, height: bh)

        // ombre au sol
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.22 + 0.1 * near))
        ctx.fillEllipse(in: CGRect(x: cx - bw * 0.42, y: ground - 1.1 * k, width: bw * 0.84, height: 2.2 * k))
        // pieds : l'un se lève pendant que l'autre porte
        for side in [-1.0, 1.0] {
            let lift = CGFloat(max(0, sin(step) * side)) * 1.3 * k
            let fx = cx + CGFloat(side) * 3.2 * k * CGFloat(abs(cos(φ))) + CGFloat(sin(φ)) * CGFloat(side * sin(step)) * 1.6 * k
            ctx.setFillColor(feet)
            ctx.fillEllipse(in: CGRect(x: fx - 2 * k, y: ground - 2.6 * k - lift, width: 4 * k, height: 2.6 * k))
        }
        // corps, éclairé d'en haut à gauche
        let path = CGPath(roundedRect: body, cornerWidth: bw * 0.45, cornerHeight: bh * 0.46, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [light, light, shade] as CFArray, locations: [0, 0.35, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: body.minX + bw * 0.36, y: body.minY + bh * 0.3), startRadius: 0,
                                   endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: bw * 0.68, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()

        // Le visage est posé sur le corps comme sur une boule : chaque trait est à un angle α de
        // l'avant ; il glisse avec la rotation et s'amincit en approchant du bord.
        func place(_ α: Double) -> (x: CGFloat, w: CGFloat)? {
            let ψ = α + φ
            guard cos(ψ) > 0.08 else { return nil }
            return (body.midX + CGFloat(sin(ψ)) * bw * 0.4, CGFloat(cos(ψ)))
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()                       // le visage reste sur le corps
        let eyeY = body.minY + bh * 0.42
        for α in [-0.45, 0.45] {
            if let c = place(α) {
                ctx.setFillColor(cheek)
                if let ch = place(α * 1.75) { ctx.fillEllipse(in: CGRect(x: ch.x - 1.3 * k * ch.w, y: eyeY + 2.6 * k, width: 2.6 * k * ch.w, height: 1.4 * k)) }
                let ew = 2.5 * k * c.w, eh = 3.5 * k
                ctx.setFillColor(ink)
                ctx.addPath(CGPath(roundedRect: CGRect(x: c.x - ew / 2, y: eyeY - eh / 2, width: ew, height: eh),
                                   cornerWidth: ew / 2 - 0.01, cornerHeight: min(ew / 2, eh / 2) - 0.01, transform: nil))
                ctx.fillPath()
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
                ctx.fillEllipse(in: CGRect(x: c.x + ew * 0.05, y: eyeY - eh * 0.36, width: 0.9 * k * c.w, height: 0.9 * k))
            }
        }
        if let m = place(0) {
            let mw = 3.2 * k * m.w, my = body.minY + bh * 0.66
            ctx.move(to: CGPoint(x: m.x - mw / 2, y: my))
            ctx.addQuadCurve(to: CGPoint(x: m.x + mw / 2, y: my), control: CGPoint(x: m.x, y: my + 1.8 * k))
            ctx.setStrokeColor(ink); ctx.setLineWidth(0.9 * k); ctx.setLineCap(.round); ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.addPath(path)                                   // contour : visible aussi sur une barre claire
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35)); ctx.setLineWidth(0.6); ctx.strokePath()
        return ctx.makeImage()
    }
}
