import SwiftUI
import AppKit

// MARK: - Aides visuelles

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension View {
    /// « Liquid Glass » sur macOS 26+, verre dépoli avant.
    @ViewBuilder func glass<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.background(VisualEffect(material: .hudWindow).clipShape(shape))
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 1))
        }
    }
}

// MARK: - Écran verrouillé

struct LockView: View {
    @ObservedObject var music: MusicWatcher
    @ObservedObject var devices: Devices
    @ObservedObject var prefs: Prefs
    @ObservedObject var lock: LockState
    let cursor: CursorModel
    let size: CGSize
    let topInset: CGFloat

    var body: some View {
        let h = size.height
        let show = (lock.visible || Demo.on) && prefs.lockScreen && music.music != nil
        let full = prefs.artBackground && music.backdrop != nil
        let art = min(h * 0.33, size.width * 0.3, 400)
        ZStack(alignment: .top) {
            if show {
                if full, let b = music.backdrop {
                    LockBackdrop(image: b, palette: music.palette, size: size)
                        .id(ObjectIdentifier(b)).transition(.opacity)
                }
                VStack(spacing: 0) {
                    if full {
                        // Le fond recouvre l'horloge de macOS : on affiche la nôtre, en verre.
                        Spacer().frame(height: topInset + h * 0.035)
                        InfoRow(devices: devices, prefs: prefs)
                        ClockView(size: h * 0.135, tint: music.accent).padding(.top, -h * 0.006)
                        Spacer().frame(height: h * 0.02)
                    } else {
                        Spacer().frame(height: h * 0.27)   // l'horloge de macOS reste visible au-dessus
                    }
                    if let m = music.music {
                        ArtworkView(music: music, cursor: cursor, side: art, playing: m.playing)
                    }
                    if prefs.showLyrics { LyricView(music: music).padding(.top, h * 0.022) }
                    MusicCard(music: music, devices: devices).padding(.top, h * (prefs.showLyrics ? 0.018 : 0.05))
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.5), value: show)
        .animation(.easeInOut(duration: 0.6), value: full)
    }
}

/// Fond de l'écran verrouillé : la pochette floutée, un dégradé « maillé » de ses
/// couleurs qui dérive lentement, un grain léger et un vignettage. Le bas redevient
/// transparent pour laisser voir la photo de session et le champ du mot de passe.
struct LockBackdrop: View {
    let image: NSImage
    let palette: [Color]
    let size: CGSize

    var body: some View {
        ZStack {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height).clipped()
                .scaleEffect(1.15)
            if palette.count == 9 { mesh.opacity(0.62) }
            // lumière douce derrière la pochette
            RadialGradient(colors: [.white.opacity(0.10), .clear], center: UnitPoint(x: 0.5, y: 0.5), startRadius: 0, endRadius: size.height * 0.5)
            Image(nsImage: Noise.image).resizable(resizingMode: .tile).opacity(0.05).blendMode(.overlay)
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: size.height * 0.35, endRadius: size.width * 0.75)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .clear, location: 0.32),
                .init(color: .clear, location: 0.7),
                .init(color: .black.opacity(0.25), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .mask(LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.74),
            .init(color: .clear, location: 0.93),
        ], startPoint: .top, endPoint: .bottom))
    }

    // Fixe : un dégradé animé coûtait 7 à 10 % de CPU en continu.
    @ViewBuilder private var mesh: some View {
        if #available(macOS 15, *) {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.42], [0.46, 0.55], [1, 0.48],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: palette, smoothsColors: true)
        } else {
            LinearGradient(colors: [palette[1], palette[4], palette[7]], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Grain fin généré une fois (évite l'aspect « plastique » des grands dégradés).
enum Noise {
    static let image: NSImage = {
        let n = 160
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 1,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: n, bitsPerPixel: 8)!
        let p = rep.bitmapData!
        var x: UInt32 = 2463534242
        for i in 0..<(n * n) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = UInt8(truncatingIfNeeded: 90 + Int(x % 76)) }
        let img = NSImage(size: NSSize(width: n, height: n)); img.addRepresentation(rep)
        return img
    }()
}

// MARK: - Notification (partout, au-dessus de tout)

struct ToastHost: View {
    @ObservedObject var devices: Devices
    @ObservedObject var target: ToastTarget
    let display: CGDirectDisplayID
    var body: some View {
        ZStack(alignment: .top) {
            if let t = devices.toast, target.display == display {
                ToastView(toast: t)
                    .padding(.top, 6)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.6, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.85, anchor: .top))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
    }
}

// MARK: Date · météo · batterie · casque

struct InfoRow: View {
    @ObservedObject var devices: Devices
    @ObservedObject var prefs: Prefs

    var body: some View {
        TimelineView(.everyMinute) { tl in
            HStack(spacing: 14) {
                Text(Self.dateText(tl.date))
                if prefs.showWeather, let w = devices.weather {
                    dot
                    HStack(spacing: 6) {
                        Image(systemName: Devices.symbol(w)).symbolRenderingMode(.multicolor)
                        Text("\(w.temp)°")
                    }
                    .help(w.city)
                }
                if prefs.showCharging, let b = devices.battery, b.charging {
                    dot
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                        Text("\(b.percent) %")
                    }
                }
                if prefs.showAirpods, let hp = devices.headphones {
                    dot
                    HStack(spacing: 5) {
                        Image(systemName: HeadphoneGlyph.symbol(hp.name))
                        if let l = HeadphoneGlyph.level(hp) { Text("\(l) %") }
                    }
                }
            }
            .font(.system(size: 21, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.88))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
            .animation(.easeInOut, value: devices.headphones)
        }
    }
    private var dot: some View { Circle().fill(.white.opacity(0.5)).frame(width: 4, height: 4) }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d MMMM"
        let s = f.string(from: d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

enum HeadphoneGlyph {
    static func symbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("max") { return "airpodsmax" }
        if n.contains("pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        return "headphones"
    }
    static func level(_ h: Headphones) -> Int? {
        if let l = h.left, let r = h.right { return min(l, r) }
        return h.left ?? h.right ?? h.level
    }
}

// MARK: Horloge en verre

struct ClockView: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        TimelineView(.everyMinute) { tl in
            let t = Self.f.string(from: tl.date)
            let text = Text(t).font(.system(size: size, weight: .semibold, design: .rounded)).kerning(-size * 0.02)
            ZStack {
                // le flou de ce qu'il y a derrière, découpé en forme de chiffres
                VisualEffect(material: .fullScreenUI).mask(text)
                text.foregroundStyle(LinearGradient(colors: [.white.opacity(0.92), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .opacity(0.62)
                // reflet en haut des chiffres
                text.foregroundStyle(LinearGradient(colors: [.white.opacity(0.9), .clear], startPoint: .top, endPoint: .center))
                    .blendMode(.overlay)
            }
            .fixedSize()
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            .contentTransition(.numericText())
            .animation(.spring(response: 0.6), value: t)
        }
    }
    static let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
}

// MARK: Pochette (légère inclinaison qui suit la souris)

struct ArtworkView: View {
    @ObservedObject var music: MusicWatcher
    @ObservedObject var cursor: CursorModel
    let side: CGFloat
    let playing: Bool

    var body: some View {
        let dx = (cursor.p.x - 0.5), dy = (cursor.p.y - 0.5)
        ZStack {
            if let img = music.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(img)).transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.08))
                Image(systemName: "music.note").font(.system(size: side * 0.25)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 40, y: 24)
        .rotation3DEffect(.degrees(Double(dx) * 9), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(Double(-dy) * 7), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(playing ? 1 : 0.88)
        .opacity(playing ? 1 : 0.85)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: playing)
        .animation(.interpolatingSpring(stiffness: 90, damping: 16), value: cursor.p)
        .onTapGesture { openPlayer() }
        .hitZone()
        .help("Ouvrir \(music.music?.source ?? "le lecteur")")
    }

    private func openPlayer() {
        let id = music.music?.source == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: Carte de lecture

struct MusicCard: View {
    @ObservedObject var music: MusicWatcher
    @ObservedObject var devices: Devices

    var body: some View {
        let m = music.music
        VStack(spacing: 10) {
            ZStack {
                VStack(spacing: 2) {
                    Text(m?.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(m?.artist ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                .padding(.horizontal, 36)
                HStack {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(music.accent)
                        .opacity(m?.playing == true ? 1 : 0.4)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let pos = music.position(at: tl.date), dur = max(m?.duration ?? 0, 1)
                HStack(spacing: 8) {
                    Text(Self.time(pos)).frame(width: 34, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * min(1, pos / dur))
                        }
                    }
                    .frame(height: 4)
                    Text("-" + Self.time(max(0, dur - pos))).frame(width: 38, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 0) {
                if m?.favorite != nil {
                    CardButton(symbol: m?.favorite == true ? "heart.fill" : "heart", size: 15, tint: m?.favorite == true ? .pink : nil) { music.toggleFavorite() }
                } else {
                    Color.clear.frame(width: 44, height: 36)
                }
                Spacer()
                CardButton(symbol: "backward.fill", size: 17) { music.control("previous track") }
                Spacer()
                CardButton(symbol: m?.playing == true ? "pause.fill" : "play.fill", size: 24) { music.control("playpause") }
                Spacer()
                CardButton(symbol: "forward.fill", size: 17) { music.control("next track") }
                Spacer()
                CardButton(symbol: devices.headphones.map { HeadphoneGlyph.symbol($0.name) } ?? "speaker.wave.2.fill", size: 15) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                .help("Sortie audio")
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
        .frame(width: 340)
        .glass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .hitZone()
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded(.down)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct CardButton: View {
    let symbol: String
    let size: CGFloat
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint ?? .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 36)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0)).frame(width: 36, height: 36))
                .scaleEffect(pressed ? 0.86 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.spring(response: 0.2)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { pressed = false } })
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: Paroles (une ligne, synchronisée)

struct LyricView: View {
    @ObservedObject var music: MusicWatcher
    var body: some View {
        // Réveil uniquement aux instants où une nouvelle ligne commence (pas de sondage).
        let now = Date(), pos = music.position(at: now)
        let dates = music.music?.playing == true
            ? [now] + music.lyrics.filter { $0.t > pos }.prefix(80).map { now.addingTimeInterval($0.t - pos - 0.2) }
            : [now]
        TimelineView(.explicit(dates)) { tl in
            let p = music.position(at: tl.date) + 0.25
            let line = music.lyrics.last { $0.t <= p }?.text ?? ""
            Text(line)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520, minHeight: 24)
                .id(line)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity.combined(with: .offset(y: -10))))
                .animation(.easeOut(duration: 0.35), value: line)
        }
    }
}

// MARK: Notifications (casque connecté, charge)

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            switch toast {
            case .headphones(let h, let vol):
                Image(systemName: HeadphoneGlyph.symbol(h.name)).font(.system(size: 16)).frame(width: 22)
                Text(h.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if let v = vol {
                    Capsule().fill(.white.opacity(0.2)).frame(width: 38, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 38 * CGFloat(v), height: 4) }
                }
                if let l = HeadphoneGlyph.level(h) { Ring(level: l) }
            case .charging(let p):
                Image(systemName: "bolt.fill").font(.system(size: 14)).foregroundStyle(.yellow)
                    .symbolEffect(.bounce, value: p)
                    .frame(width: 22)
                Text("En charge").font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 6)
                Text("\(p) %").font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(p >= 20 ? .green : .orange)
                Ring(level: p)
            }
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(width: 236, height: 40)
        .background(Capsule().fill(.black))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }
}

struct Ring: View {
    let level: Int
    @State private var shown = false
    var body: some View {
        let c: Color = level >= 20 ? .green : .orange
        ZStack {
            Circle().stroke(c.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: shown ? CGFloat(level) / 100 : 0)
                .stroke(c, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .help("\(level) %")
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { shown = true } }
    }
}
