import SwiftUI
import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let prefs = Prefs.shared
    let music = MusicWatcher()
    let devices = Devices()
    private var screens: ScreenManager!
    private var status: NSStatusItem!
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        // Une seule instance à la fois (sinon les fenêtres s'empilent).
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) { NSApp.terminate(nil); return }

        music.start()
        devices.start()
        screens = ScreenManager(music: music, devices: devices, prefs: prefs)
        screens.rebuild()
        buildStatusItem()
        if !Demo.on { Updater.shared.startAutomaticChecks() }
        if ProcessInfo.processInfo.environment["OSAWALLPAPER_UPDATE_TEST"] != nil {
            // test de bout en bout : installe la dernière release sans demander
            Updater.shared.check { r in if let r { Updater.shared.install(r) } else { NSLog("OsaWallpaper update test: rien de plus récent") } }
        }

        if Demo.on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.devices.show(.headphones(Headphones(name: "AirPods Pro", left: 82, right: 79, caseLevel: 60), volume: 0.62), for: 6)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.devices.show(.charging(64), for: 5) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.devices.show(.volume(0.56, muted: false, symbol: "speaker.wave.2.fill"), for: 3) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 19) { self.devices.show(.brightness(0.72), for: 3) }
            if ProcessInfo.processInfo.environment["OSAWALLPAPER_ONBOARDING"] != nil { openOnboarding() }
        } else if ProcessInfo.processInfo.environment["OSAWALLPAPER_TOAST_TEST"] != nil {
            // test réel des pastilles (au-dessus de tout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.devices.show(.headphones(Headphones(name: "AirPods Pro", left: 82, right: 79, caseLevel: 60), volume: 0.62), for: 4)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { self.devices.show(.charging(64), for: 4) }
        } else if !prefs.onboarded {
            openOnboarding()
        }
    }

    // MARK: Barre de menus (icône + météo)
    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        devices.$weather.combineLatest(prefs.$weatherInMenuBar).receive(on: RunLoop.main)
            .sink { [weak self] w, on in self?.updateStatusButton(w, on) }.store(in: &bag)
    }

    private func updateStatusButton(_ w: Weather?, _ on: Bool) {
        guard let b = status.button else { return }
        if on, let w {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.white, .systemYellow])
                .applying(.init(pointSize: 13, weight: .medium))
            b.image = NSImage(systemSymbolName: Devices.symbol(w), accessibilityDescription: "Météo")?.withSymbolConfiguration(cfg)
            b.image?.isTemplate = false
            b.imagePosition = .imageLeading
            b.title = " \(w.temp)°"
            b.toolTip = w.city.isEmpty ? "OsaWallpaper" : "\(w.city) · OsaWallpaper"
        } else {
            b.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "OsaWallpaper")
            b.image?.isTemplate = true
            b.title = ""
            b.toolTip = "OsaWallpaper"
        }
    }

    // MARK: Fenêtres
    @objc func openSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Réglages d’OsaWallpaper"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(prefs: prefs, devices: devices, music: music,
                                                                 onPreview: { [weak self] in self?.preview() }))
            w.center()
            settings = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc func openOnboarding() {
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
            w.contentView = NSHostingView(rootView: OnboardingView(prefs: prefs, music: music,
                onPreview: { [weak self] in self?.preview() },
                onFinish: { [weak self] in self?.prefs.onboarded = true; self?.onboarding?.close() }))
            w.center()
            onboarding = w
        }
        if Demo.on { onboarding?.orderBack(nil); return }   // tests : ne vole pas le focus
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.makeKeyAndOrderFront(nil)
    }

    @objc func preview() { screens.showPreview() }
    @objc private func toggleLock() { prefs.lockScreen.toggle() }
    @objc private func toggleArt() { prefs.artBackground.toggle() }
    @objc private func toggleWeather() { prefs.weatherInMenuBar.toggle() }
    @objc private func toggleLogin() { LoginItem.toggle() }
    @objc private func checkUpdates() { Updater.shared.checkNow() }
    @objc private func installUpdate() { if let r = Updater.shared.available { Updater.shared.install(r) } }
}

extension AppDelegate: NSMenuDelegate {
    // Le menu est reconstruit à chaque ouverture : les coches reflètent l'état réel.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ t: String, _ sel: Selector?, _ key: String = "", on: Bool? = nil, enabled: Bool = true) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.target = self
            i.isEnabled = enabled
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        if let w = devices.weather {
            let i = NSMenuItem(title: "\(w.city.isEmpty ? "Météo" : w.city) · \(w.temp)°", action: nil, keyEquivalent: "")
            i.isEnabled = false; menu.addItem(i)
        }
        if let m = music.music {
            let i = NSMenuItem(title: "\(m.playing ? "♪" : "⏸") \(m.title) — \(m.artist)", action: nil, keyEquivalent: "")
            i.isEnabled = false; menu.addItem(i)
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }
        item("Sur l’écran verrouillé", #selector(toggleLock), on: prefs.lockScreen)
        item("Fond tiré de la pochette", #selector(toggleArt), on: prefs.artBackground)
        item("Météo dans la barre de menus", #selector(toggleWeather), on: prefs.weatherInMenuBar)
        item(music.music == nil ? "Aperçu (lance un morceau)" : "Aperçu de l’écran verrouillé", #selector(preview), enabled: music.music != nil)
        menu.addItem(.separator())
        item("Réglages…", #selector(openSettings), ",")
        item("Bienvenue…", #selector(openOnboarding))
        item("Ouvrir au démarrage du Mac", #selector(toggleLogin), on: LoginItem.enabled)
        if let r = Updater.shared.available {
            item("Installer la version \(r.version)…", #selector(installUpdate))
        } else {
            item("Rechercher des mises à jour…", #selector(checkUpdates))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter OsaWallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func toggle() {
        do { enabled ? try SMAppService.mainApp.unregister() : try SMAppService.mainApp.register() }
        catch { NSSound.beep() }
    }
}

// MARK: Réglages

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var devices: Devices
    @ObservedObject var music: MusicWatcher
    var onPreview: () -> Void
    @State private var city = Prefs.shared.city
    @State private var login = LoginItem.enabled

    var body: some View {
        Form {
            Section {
                Toggle("Afficher sur l’écran verrouillé", isOn: $prefs.lockScreen)
                Toggle("Fond tiré de la pochette", isOn: $prefs.artBackground)
                Toggle("Pochettes animées d’Apple Music (quand l’artiste en a une)", isOn: $prefs.motionArt)
                Toggle("Paroles synchronisées", isOn: $prefs.showLyrics)
                Toggle("Sur tous les écrans", isOn: $prefs.allScreens)
                Button(music.music == nil ? "Aperçu : lance d’abord un morceau" : "Aperçu (8 s)", action: onPreview).disabled(music.music == nil)
            } header: { Text("Écran verrouillé") } footer: {
                Text("Visible seulement quand ton Mac est verrouillé (⌃⌘Q) et qu’un morceau joue.").foregroundStyle(.secondary)
            }
            Section("Partout") {
                Toggle("AirPods et casques (batterie, volume)", isOn: $prefs.showAirpods)
                Toggle("Charge du Mac", isOn: $prefs.showCharging)
                Toggle("Volume", isOn: $prefs.showVolume)
                Toggle("Luminosité (touches F1 / F2)", isOn: $prefs.showBrightness)
                Toggle("Remplacer les indicateurs son / luminosité de macOS", isOn: $prefs.hideSystemHUD)
                if (prefs.showBrightness || prefs.hideSystemHUD) && !Devices.accessibilityGranted {
                    HStack {
                        Text("macOS doit autoriser OsaWallpaper à voir les touches son et luminosité (Accessibilité).")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Autoriser") {
                            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        }
                    }
                }
                Toggle("Météo dans la barre de menus", isOn: $prefs.weatherInMenuBar)
                Toggle("Météo sur l’écran verrouillé", isOn: $prefs.showWeather)
            }
            Section {
                HStack {
                    TextField("Ville", text: $city, prompt: Text("Automatique (selon ta connexion)"))
                        .onSubmit(applyCity)
                    Button("OK", action: applyCity)
                }
                if let w = devices.weather {
                    Label("\(w.city.isEmpty ? "Position actuelle" : w.city) · \(w.temp)°", systemImage: Devices.symbol(w))
                        .symbolRenderingMode(.multicolor).foregroundStyle(.secondary)
                }
            } header: { Text("Météo") } footer: {
                Text("Laisse vide pour une position approximative déduite de ta connexion. Données Open-Meteo.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ouvrir au démarrage du Mac", isOn: Binding(get: { login }, set: { _ in LoginItem.toggle(); login = LoginItem.enabled }))
                HStack {
                    Button("Tester : AirPods") {
                        devices.show(.headphones(devices.headphones ?? Headphones(name: "AirPods Pro", left: 82, right: 80, caseLevel: 64), volume: devices.volume ?? 0.6))
                    }
                    Button("Tester : charge") { devices.show(.charging(devices.battery?.percent ?? 82), for: 4) }
                    Button("Tester : volume") { devices.show(.volume(devices.volume ?? 0.5, muted: false, symbol: "speaker.wave.2.fill"), for: 2) }
                }
                Toggle("Rechercher les mises à jour automatiquement", isOn: $prefs.autoUpdate)
                HStack {
                    Text("Version \(Updater.current)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Rechercher maintenant") { Updater.shared.checkNow() }
                }
            } header: { Text("Général") } footer: {
                Text("OsaWallpaper · OsaLabs").foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 680)
    }

    private func applyCity() {
        prefs.city = city.trimmingCharacters(in: .whitespaces)
        devices.refreshWeather()
    }
}
