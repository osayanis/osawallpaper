import SwiftUI
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let prefs = Prefs.shared
    let music = MusicWatcher()
    let devices = Devices()
    private var screens: ScreenManager!
    private var status: NSStatusItem!
    private var settings: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        // Une seule instance à la fois (sinon les fenêtres de fond s'empilent).
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) { NSApp.terminate(nil); return }

        music.start()
        devices.start()
        screens = ScreenManager(music: music, devices: devices, prefs: prefs)
        screens.rebuild()
        buildStatusItem()
        if ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.devices.show(.headphones(Headphones(name: "AirPods Pro", left: 82, right: 79, caseLevel: 60), volume: 0.62), for: 6)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.devices.show(.charging(64), for: 5) }
        }
    }

    // MARK: Barre de menus
    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "OsaWallpaper")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
    }

    @objc func openSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "OsaWallpaper"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(prefs: prefs, devices: devices))
            w.center()
            settings = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleWidgets() { prefs.hideWidgets.toggle() }
    @objc private func toggleArt() { prefs.artBackground.toggle() }
    @objc private func toggleLogin() { LoginItem.toggle() }
}

extension AppDelegate: NSMenuDelegate {
    // Le menu est reconstruit à chaque ouverture : les coches reflètent l'état réel.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ t: String, _ sel: Selector?, _ key: String = "", on: Bool? = nil) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        if let m = music.music {
            let i = NSMenuItem(title: "\(m.playing ? "♪" : "⏸") \(m.title) — \(m.artist)", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i); menu.addItem(.separator())
        }
        item("Afficher les widgets", #selector(toggleWidgets), on: !prefs.hideWidgets)
        item("Fond tiré de la pochette", #selector(toggleArt), on: prefs.artBackground)
        menu.addItem(.separator())
        item("Réglages…", #selector(openSettings), ",")
        item("Ouvrir au démarrage du Mac", #selector(toggleLogin), on: LoginItem.enabled)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quitter OsaWallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
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
    @State private var city = Prefs.shared.city
    @State private var login = LoginItem.enabled

    var body: some View {
        Form {
            Section("Fond d'écran") {
                Toggle("Fond tiré de la pochette pendant la lecture", isOn: $prefs.artBackground)
                Toggle("Sur tous les écrans", isOn: $prefs.allScreens)
                Toggle("Afficher les widgets", isOn: Binding(get: { !prefs.hideWidgets }, set: { prefs.hideWidgets = !$0 }))
            }
            Section("Widgets") {
                Toggle("Paroles synchronisées", isOn: $prefs.showLyrics)
                Toggle("Météo", isOn: $prefs.showWeather)
                Toggle("AirPods et casques (batterie, volume)", isOn: $prefs.showAirpods)
                Toggle("Charge du Mac", isOn: $prefs.showCharging)
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
                    Button("Aperçu : AirPods") {
                        devices.show(.headphones(devices.headphones ?? Headphones(name: "AirPods Pro", left: 82, right: 80, caseLevel: 64), volume: devices.volume ?? 0.6))
                    }
                    Button("Aperçu : charge") { devices.show(.charging(devices.battery?.percent ?? 82), for: 4) }
                }
            } header: { Text("Général") } footer: {
                Text("OsaWallpaper · OsaLabs").foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
    }

    private func applyCity() {
        prefs.city = city.trimmingCharacters(in: .whitespaces)
        devices.refreshWeather()
    }
}
