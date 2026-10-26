import SwiftUI
import AppKit
import Carbon

// Autorisation « Automatisation » (piloter Music / Spotify) : la seule dont OsaWallpaper a besoin.
enum Automation {
    enum State { case granted, denied, unknown, notRunning }

    static func status(_ bundleID: String, ask: Bool) -> State {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }

    static func installed(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }
    static func running(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

    /// Lance l'app en arrière-plan si besoin, puis fait apparaître la demande de macOS.
    static func request(_ id: String, done: @escaping (State) -> Void) {
        func ask() { DispatchQueue.global(qos: .userInitiated).async { let s = status(id, ask: true); DispatchQueue.main.async { done(s) } } }
        if running(id) { ask(); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { done(.unknown); return }
        let c = NSWorkspace.OpenConfiguration(); c.activates = false; c.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: c) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ask() }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

struct OnboardingView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var music: MusicWatcher
    var onPreview: () -> Void
    var onFinish: () -> Void

    @State private var step = Int(ProcessInfo.processInfo.environment["OSAWALLPAPER_ONBOARDING"] ?? "") ?? 0
    @State private var forward = true

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06)
            // halo de couleur qui change à chaque étape
            Circle()
                .fill(RadialGradient(colors: [[Color(red: 0.43, green: 0.55, blue: 1), Color(red: 0.98, green: 0.6, blue: 0.82), Color(red: 0.45, green: 0.85, blue: 0.75)][step].opacity(0.45), .clear],
                                     center: .center, startRadius: 0, endRadius: 260))
                .frame(width: 560, height: 560)
                .offset(y: -230)
                .blur(radius: 30)
                .animation(.easeInOut(duration: 0.8), value: step)

            VStack(spacing: 0) {
                ZStack {
                    switch step {
                    case 0: WelcomeStep().transition(slide)
                    case 1: PermissionStep(prefs: prefs).transition(slide)
                    default: ReadyStep(music: music, onPreview: onPreview).transition(slide)
                    }
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 7) {
                    ForEach(0..<3) { i in
                        Capsule().fill(.white.opacity(i == step ? 0.9 : 0.2)).frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: step)
                .padding(.bottom, 18)

                HStack {
                    if step > 0 {
                        Button("Retour") { go(step - 1) }.buttonStyle(GhostButton())
                    }
                    Spacer()
                    Button(step == 2 ? "Terminer" : "Continuer") {
                        if step == 2 { onFinish() } else { go(step + 1) }
                    }
                    .buttonStyle(MainButton())
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 28).padding(.bottom, 26)
            }
            .padding(.top, 30)
        }
        .frame(width: 540, height: 600)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
    private func go(_ s: Int) {
        forward = s > step
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = s }
    }
}

// MARK: Étape 1 — bienvenue

private struct WelcomeStep: View {
    @State private var float = false
    var body: some View {
        VStack(spacing: 18) {
            // L'icône du bundle telle quelle (NSApp.applicationIconImage suit le style d'icônes choisi dans macOS).
            Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage)
                .resizable().frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                .scaleEffect(float ? 1 : 0.6)
                .opacity(float ? 1 : 0)
                .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.1)) { float = true } }
            Text("Bienvenue dans OsaWallpaper")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Quand ton Mac est verrouillé, ton écran prend les couleurs de ta musique : l’heure en verre, la pochette, les commandes et les paroles.")
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            VStack(spacing: 10) {
                Feature(icon: "lock.fill", tint: .blue, title: "Écran verrouillé", text: "Pochette, lecteur et paroles, sur tous tes écrans.")
                Feature(icon: "airpodspro", tint: .green, title: "AirPods et charge, partout", text: "Une pastille avec la batterie dès qu’ils se connectent.")
                Feature(icon: "cloud.sun.fill", tint: .yellow, title: "La météo, en haut", text: "La température dans la barre de menus.")
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 36)
    }
}

private struct Feature: View {
    let icon: String, tint: Color, title: String, text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 38, height: 38).background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
        .frame(maxWidth: 420)
    }
}

// MARK: Étape 2 — autorisations

private struct PermissionStep: View {
    @ObservedObject var prefs: Prefs
    @State private var login = LoginItem.enabled

    private var apps: [(id: String, name: String, icon: String)] {
        var a: [(String, String, String)] = []
        if Automation.installed("com.apple.Music") { a.append(("com.apple.Music", "Music", "music.note")) }
        if Automation.installed("com.spotify.client") { a.append(("com.spotify.client", "Spotify", "waveform")) }
        return a
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill").font(.system(size: 34)).foregroundStyle(.pink)
                .frame(width: 72, height: 72).background(Circle().fill(.pink.opacity(0.15)))
            Text("Une seule autorisation")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("OsaWallpaper lit le morceau en cours dans ton lecteur pour l’afficher. macOS va te demander si tu l’acceptes.")
                .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).frame(maxWidth: 400)

            VStack(spacing: 10) {
                ForEach(apps, id: \.id) { a in PermissionRow(bundleID: a.id, name: a.name, icon: a.icon) }
                HStack(spacing: 14) {
                    Image(systemName: "power").font(.system(size: 16, weight: .semibold)).foregroundStyle(.orange)
                        .frame(width: 38, height: 38).background(Circle().fill(.orange.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ouvrir au démarrage du Mac").font(.system(size: 13, weight: .semibold))
                        Text("Pour que ton écran verrouillé soit toujours prêt.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { login }, set: { _ in LoginItem.toggle(); login = LoginItem.enabled }))
                        .toggleStyle(.switch).labelsHidden()
                }
                .rowStyle()
            }
            .padding(.top, 8)

            Label("Pas de caméra, pas de micro, pas de localisation : la météo se contente d’une position approximative.", systemImage: "checkmark.shield.fill")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420).padding(.top, 6)
        }
        .padding(.horizontal, 36)
    }
}

private struct PermissionRow: View {
    let bundleID: String, name: String, icon: String
    @State private var state: Automation.State = .unknown
    @State private var asking = false
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.pink)
                .frame(width: 38, height: 38).background(Circle().fill(.pink.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Piloter \(name)").font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .denied:
                Button("Réglages") { Automation.openSettings() }.buttonStyle(SmallButton(tint: .orange))
            default:
                Button(asking ? "…" : "Autoriser") {
                    asking = true
                    Automation.request(bundleID) { s in withAnimation(.spring) { state = s; asking = false } }
                }
                .buttonStyle(SmallButton(tint: .pink)).disabled(asking)
            }
        }
        .rowStyle()
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private var subtitle: String {
        switch state {
        case .granted: return "Autorisé"
        case .denied: return "Refusé : à réactiver dans Réglages Système"
        default: return "Pour afficher le morceau en cours"
        }
    }
    private func refresh() {
        let id = bundleID
        DispatchQueue.global(qos: .utility).async {
            let s = Automation.status(id, ask: false)
            DispatchQueue.main.async { if s != .notRunning || state == .unknown { withAnimation(.spring) { state = s == .notRunning ? .unknown : s } } }
        }
    }
}

// MARK: Étape 3 — c'est prêt

private struct ReadyStep: View {
    @ObservedObject var music: MusicWatcher
    var onPreview: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // mini écran verrouillé
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.42), Color(red: 0.36, green: 0.55, blue: 0.85), Color(red: 0.95, green: 0.6, blue: 0.8)], startPoint: .top, endPoint: .bottom))
                VStack(spacing: 8) {
                    Text("09:41").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.25)).frame(width: 64, height: 64)
                        .overlay(Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.8)))
                    Capsule().fill(.white.opacity(0.2)).frame(width: 110, height: 22)
                }
            }
            .frame(width: 240, height: 170)
            .shadow(color: .black.opacity(0.4), radius: 22, y: 12)

            Text("C’est prêt !")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Lance un morceau puis verrouille ton Mac pour voir le résultat. Les pastilles AirPods et charge, elles, apparaissent partout.")
                .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            HStack(spacing: 6) {
                ForEach(["⌃", "⌘", "Q"], id: \.self) { k in
                    Text(k).font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(minWidth: 34, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15)))
                }
                Text("pour verrouiller").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).padding(.leading, 6)
            }
            Button(action: onPreview) {
                Label(music.music == nil ? "Lance un morceau pour l’aperçu" : "Voir l’aperçu (8 s)", systemImage: "eye.fill")
            }
            .buttonStyle(GhostButton())
            .disabled(music.music == nil)
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
    }
}

// MARK: Styles

private extension View {
    func rowStyle() -> some View {
        padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
            .frame(maxWidth: 440)
    }
}

struct MainButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(Capsule().fill(.white))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}

struct GhostButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.35))
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Capsule())
    }
}

struct SmallButton: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(tint))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
