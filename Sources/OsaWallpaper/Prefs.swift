import SwiftUI

// Réglages persistés (UserDefaults). Chaque changement est publié → l'UI suit.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var artBackground: Bool { didSet { d.set(artBackground, forKey: "artBackground") } }
    @Published var showWeather: Bool { didSet { d.set(showWeather, forKey: "showWeather") } }
    @Published var showLyrics: Bool { didSet { d.set(showLyrics, forKey: "showLyrics") } }
    @Published var showAirpods: Bool { didSet { d.set(showAirpods, forKey: "showAirpods") } }
    @Published var showCharging: Bool { didSet { d.set(showCharging, forKey: "showCharging") } }
    @Published var showVolume: Bool { didSet { d.set(showVolume, forKey: "showVolume") } }
    @Published var showBrightness: Bool { didSet { d.set(showBrightness, forKey: "showBrightness") } }
    @Published var autoUpdate: Bool { didSet { d.set(autoUpdate, forKey: "autoUpdate") } }
    @Published var motionArt: Bool { didSet { d.set(motionArt, forKey: "motionArt") } }          // pochettes animées Apple Music
    @Published var hideSystemHUD: Bool { didSet { d.set(hideSystemHUD, forKey: "hideSystemHUD") } }  // remplace les indicateurs de macOS
    @Published var allScreens: Bool { didSet { d.set(allScreens, forKey: "allScreens") } }
    @Published var lockScreen: Bool { didSet { d.set(lockScreen, forKey: "lockScreen") } }        // affichage sur l'écran verrouillé
    @Published var weatherInMenuBar: Bool { didSet { d.set(weatherInMenuBar, forKey: "weatherInMenuBar") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    @Published var city: String { didSet { d.set(city, forKey: "city") } }   // vide = position approximative (IP)

    private init() {
        d.register(defaults: [
            "artBackground": true, "showWeather": true, "showLyrics": true,
            "showAirpods": true, "showCharging": true, "showVolume": true, "showBrightness": true, "autoUpdate": true, "motionArt": true, "hideSystemHUD": true, "allScreens": true, "lockScreen": true, "weatherInMenuBar": true, "onboarded": false,
        ])
        artBackground = d.bool(forKey: "artBackground")
        showWeather = d.bool(forKey: "showWeather")
        showLyrics = d.bool(forKey: "showLyrics")
        showAirpods = d.bool(forKey: "showAirpods")
        showCharging = d.bool(forKey: "showCharging")
        showVolume = d.bool(forKey: "showVolume")
        showBrightness = d.bool(forKey: "showBrightness")
        autoUpdate = d.bool(forKey: "autoUpdate")
        motionArt = d.bool(forKey: "motionArt")
        hideSystemHUD = d.bool(forKey: "hideSystemHUD")
        allScreens = d.bool(forKey: "allScreens")
        lockScreen = d.bool(forKey: "lockScreen")
        weatherInMenuBar = d.bool(forKey: "weatherInMenuBar")
        onboarded = d.bool(forKey: "onboarded")
        city = d.string(forKey: "city") ?? ""
    }
}
