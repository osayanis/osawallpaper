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
    private var onboarding: NSWindow?
    private var gallery: NSWindow?
    private var desktop: DesktopWallpaper?
    private var awake: ScreenAwake!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        // Une seule instance à la fois (sinon les fenêtres s'empilent).
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) { NSApp.terminate(nil); return }

        buildMainMenu()
        // Fenêtre fermée : s'il n'en reste aucune, l'icône quitte le Dock (l'app continue en fond).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, [self.gallery, self.onboarding].contains(where: { $0 === w }) else { return }
            DispatchQueue.main.async { self.windowsChanged() }
        }

        music.start()
        devices.start()
        screens = ScreenManager(music: music, devices: devices, prefs: prefs)
        screens.rebuild()
        desktop = DesktopWallpaper(store: WallpaperStore.shared, prefs: prefs, lock: screens.lock, music: music)
        awake = ScreenAwake(lock: screens.lock, prefs: prefs)
        if let s = ProcessInfo.processInfo.environment["OSAWALLPAPER_AWAKE_TEST"], let t = Double(s) { awake.test(seconds: t) }
        buildStatusItem()
        if !Demo.on {
            Updater.shared.canRelaunch = { [weak self] in
                guard let self else { return false }
                return !self.screens.lock.locked && !self.screens.lock.preview
                    && ![self.gallery, self.onboarding].contains { $0?.isVisible == true }
            }
            Updater.shared.startAutomaticChecks()
            if let from = UserDefaults.standard.string(forKey: "updatedFrom") {
                UserDefaults.standard.removeObject(forKey: "updatedFrom")
                if from != Updater.current {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.devices.show(.updated(Updater.current), for: 4) }
                }
            }
        }
        if ProcessInfo.processInfo.environment["OSAWALLPAPER_UPDATE_TEST"] != nil {
            // test de bout en bout : installe la dernière release sans demander
            Updater.shared.check { r in if let r { Updater.shared.install(r) } else { NSLog("OsaWallpaper update test: rien de plus récent") } }
        }

        if Demo.on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // OSAWALLPAPER_DEMO_HP=201F : la notif d'un modèle précis (Product ID Bluetooth)
                let id = ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO_HP"].flatMap { Int($0, radix: 16) } ?? 0x2014
                self.devices.show(.headphones(Headphones(name: "AirPods", left: 82, right: 79, caseLevel: 60, productID: id), volume: 0.62), for: 6)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.devices.show(.charging(64), for: 5) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.devices.show(.volume(0.56, muted: false, symbol: "speaker.wave.2.fill"), for: 3) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 19) { self.devices.show(.brightness(0.72), for: 3) }
            if ProcessInfo.processInfo.environment["OSAWALLPAPER_ONBOARDING"] != nil { openOnboarding() }
            if ProcessInfo.processInfo.environment["OSAWALLPAPER_GALLERY"] != nil { openGallery() }
            // OSAWALLPAPER_BG_TEST : icône dans le Dock, puis passage en arrière-plan (pastille).
            if ProcessInfo.processInfo.environment["OSAWALLPAPER_BG_TEST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.showInDock(); NSLog("OsaWallpaper test: policy=\(NSApp.activationPolicy().rawValue)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.toBackground(); NSLog("OsaWallpaper test: policy=\(NSApp.activationPolicy().rawValue)") }
            }
            if ProcessInfo.processInfo.environment["OSAWALLPAPER_OVER_MUSIC"] != nil { prefs.wallpaperOverMusic = true }
            // OSAWALLPAPER_DEMO_LOGIN : connexion de macOS simulée (photo, nom, champ) pour le plein écran vidéo.
            if ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO_LOGIN"] != nil, let s = NSScreen.main?.frame {
                let primary = NSScreen.screens.first?.frame.height ?? s.height, top = primary - s.maxY, cx = s.midX
                // nom placé comme sur l'écran verrouillé réel d'un MacBook Air 13" (relevé par l'Accessibilité)
                let n = CGRect(x: cx - 54.75, y: top + s.height - 103.5, width: 109.5, height: 21)
                LoginUI.shared.demo(.init(avatar: CGRect(x: n.midX - 30, y: n.minY - 70, width: 60, height: 60), name: n,
                                          field: CGRect(x: n.midX - 100, y: n.maxY + 12, width: 200, height: 30)))
            }
            // OSAWALLPAPER_APPLY=<fichier ou lien> : utilise ce fond tout de suite.
            if let a = ProcessInfo.processInfo.environment["OSAWALLPAPER_APPLY"] {
                if FileManager.default.fileExists(atPath: a) { WallpaperStore.shared.importFile(URL(fileURLWithPath: a)) }
                else if let w = WallpaperStore.fromLink(a) { WallpaperStore.shared.apply(w) }
            }
            // OSAWALLPAPER_SNAP=<dossier> : l'app enregistre ses propres fenêtres en PNG (tests visuels).
            if let dir = ProcessInfo.processInfo.environment["OSAWALLPAPER_SNAP"] {
                Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in Snap.windows(to: dir) }
            }
        } else if ProcessInfo.processInfo.environment["OSAWALLPAPER_LOCKSWAP_TEST"] != nil {
            // test réel du plein écran : fond macOS changé « pendant le verrouillage » puis remis
            // (sans verrouiller ni afficher l'écran verrouillé)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.desktop?.lockChanged(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSLog("OsaWallpaper test: zone ouverte=\(LockHole.shared.open)"); self.desktop?.lockChanged(false) }
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
    /// Les réglages sont un onglet de la fenêtre principale (à droite de « Mes fonds »).
    @objc func openSettings() { showGallery(tab: .settings) }

    @objc func openGallery() { showGallery(tab: nil) }

    func showGallery(tab: GalleryTab?) {
        if let tab {
            GalleryModel.requestedTab = tab
            NotificationCenter.default.post(name: .osaGalleryTab, object: tab)
        }
        if gallery == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Fonds d’écran"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
            w.contentMinSize = NSSize(width: 980, height: 640)
            w.contentView = NSHostingView(rootView: GalleryView(store: WallpaperStore.shared, prefs: prefs,
                                                                onPreview: { [weak self] in self?.preview() },
                                                                settings: AnyView(SettingsView(prefs: prefs, devices: devices, music: music,
                                                                                               onPreview: { [weak self] in self?.preview() }, embedded: true))))
            w.center()
            gallery = w
        }
        if Demo.on { gallery?.orderFrontRegardless(); return }   // tests : ne vole pas le focus
        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        gallery?.makeKeyAndOrderFront(nil)
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
        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.makeKeyAndOrderFront(nil)
    }

    // MARK: Dock et arrière-plan
    // Une fenêtre ouverte (galerie, réglages, bienvenue) : l'icône est dans le Dock. Toutes fermées
    // (ou ⌘Q, ou « Quitter » dans le Dock) : l'icône disparaît, l'app continue en arrière-plan
    // (écran verrouillé, pastilles, bureau) et une pastille le dit. Quitter pour de bon : ⌥⌘Q
    // ou le menu de la barre des menus.

    private func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    private func windowsChanged() {
        let open = [gallery, onboarding].contains { $0?.isVisible == true || $0?.isMiniaturized == true }
        guard !open, NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
        devices.show(.background, for: 3.5)
    }

    @objc func toBackground() {
        [gallery, onboarding].forEach { $0?.close() }
        windowsChanged()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // « Quitter » dans le Dock : un Apple Event sans raison (une déconnexion ou un arrêt en ont une).
        let ae = NSAppleEventManager.shared().currentAppleEvent
        let fromDock = ae?.eventID == kAEQuitApplication && ae?.attributeDescriptor(forKeyword: kAEQuitReason) == nil
        if fromDock, NSApp.activationPolicy() == .regular { toBackground(); return .terminateCancel }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openGallery() }
        return true
    }

    private func buildMainMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let i = NSMenuItem(); i.submenu = m; main.addItem(i)
        }
        func item(_ t: String, _ a: Selector, _ k: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = target; return i
        }
        sub("OsaWallpaper", [
            item("Choisir un fond d’écran…", #selector(openGallery), "f", target: self),
            item("Réglages…", #selector(openSettings), ",", target: self),
            .separator(),
            item("Mettre en arrière-plan", #selector(toBackground), "q", target: self),
            item("Quitter complètement", #selector(NSApplication.terminate(_:)), "q", [.command, .option]),
        ])
        // Édition : copier-coller dans la recherche et le champ du lien.
        sub("Édition", [
            item("Annuler", Selector(("undo:")), "z"), item("Rétablir", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Couper", #selector(NSText.cut(_:)), "x"), item("Copier", #selector(NSText.copy(_:)), "c"),
            item("Coller", #selector(NSText.paste(_:)), "v"), item("Tout sélectionner", #selector(NSText.selectAll(_:)), "a"),
        ])
        sub("Fenêtre", [
            item("Fermer", #selector(NSWindow.performClose(_:)), "w"),
            item("Réduire", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.mainMenu = main
    }

    @objc func preview() { screens.showPreview() }
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
        // Le reste est dans l'onglet « Réglages » de la fenêtre.
        item("Ouvrir OsaWallpaper…", #selector(openGallery), "o")
        let canPreview = music.music != nil || WallpaperStore.shared.current != nil
        item(canPreview ? "Aperçu de l’écran verrouillé" : "Aperçu (lance un morceau)", #selector(preview), enabled: canPreview)
        item("Réglages…", #selector(openSettings), ",")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter OsaWallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

enum Snap {
    static func windows(to dir: String) {
        for w in NSApp.windows where w.isVisible {
            guard let v = w.contentView, v.bounds.width > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let name = w.title.isEmpty ? "win-\(Int(v.bounds.width))x\(Int(v.bounds.height))" : "gallery"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
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
    @ObservedObject var wall = WallpaperStore.shared
    var onPreview: () -> Void
    var embedded = false                         // dans l'onglet « Réglages » de la fenêtre principale
    @State private var city = Prefs.shared.city
    @State private var login = LoginItem.enabled

    var body: some View {
        Form {
            Section {
                Toggle("Afficher sur l’écran verrouillé", isOn: $prefs.lockScreen)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fond d’écran personnalisé")
                        Text(wall.current.map { $0.title } ?? "Aucun : la pochette du morceau").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choisir…") { AppDelegate.shared?.openGallery() }
                }
                if wall.current != nil {
                    Toggle("Garder mon fond même pendant la musique", isOn: $prefs.wallpaperOverMusic)
                    Toggle("Aussi en fond du bureau (Mac déverrouillé)", isOn: $prefs.desktopToo)
                    if prefs.desktopToo, let k = wall.current?.kind, k != .image {
                        Toggle("Vidéo animée sur le bureau", isOn: $prefs.desktopAnimated)
                    }
                }
                Picker("Fond sur l’écran verrouillé", selection: $prefs.lockFullScreen) {
                    Text("Fondu en bas").tag(false)
                    Text("Plein écran").tag(true)
                }
                Picker("Écran allumé une fois verrouillé", selection: $prefs.lockAwakeMinutes) {
                    Text("Comme macOS").tag(0)
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
                Toggle("Fond tiré de la pochette", isOn: $prefs.artBackground)
                Toggle("Pochettes animées d’Apple Music (quand l’artiste en a une)", isOn: $prefs.motionArt)
                Toggle("Paroles synchronisées", isOn: $prefs.showLyrics)
                Toggle("Sur tous les écrans", isOn: $prefs.allScreens)
                Button(music.music == nil && wall.current == nil ? "Aperçu : lance d’abord un morceau" : "Aperçu (8 s)", action: onPreview)
                    .disabled(music.music == nil && wall.current == nil)
            } header: { Text("Écran verrouillé") } footer: {
                Text("Visible seulement quand ton Mac est verrouillé (⌃⌘Q), avec un morceau en cours ou ton fond personnalisé. « Écran allumé » : garde l’écran allumé le temps choisi après ta dernière action, puis macOS l’éteint (jamais en mode économie d’énergie).").foregroundStyle(.secondary)
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
                Toggle("Installer les mises à jour automatiquement", isOn: $prefs.autoUpdate)
                HStack {
                    Text("Version \(Updater.current)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Revoir la bienvenue") { AppDelegate.shared?.openOnboarding() }
                    Button("Rechercher maintenant") { Updater.shared.checkNow() }
                }
            } header: { Text("Général") } footer: {
                Text("OsaWallpaper · OsaLabs").foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(embedded ? .hidden : .automatic)
        .frame(width: embedded ? nil : 460, height: embedded ? nil : 680)
        .frame(maxWidth: embedded ? 640 : nil)
    }

    private func applyCity() {
        prefs.city = city.trimmingCharacters(in: .whitespaces)
        devices.refreshWeather()
    }
}
