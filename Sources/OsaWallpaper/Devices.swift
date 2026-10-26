import SwiftUI
import AppKit
import IOKit.ps
import CoreAudio
import AudioToolbox
import os
import notify

let log = Logger(subsystem: "com.osalabs.osawallpaper", category: "devices")

struct Headphones: Equatable { var name: String; var level: Int?; var left: Int?; var right: Int?; var caseLevel: Int? }
struct Weather: Equatable { var temp: Int; var code: Int; var isDay: Bool; var city: String }

enum Toast: Equatable, Identifiable {
    case headphones(Headphones, volume: Float?)
    case charging(Int)
    case volume(Float, muted: Bool, symbol: String)
    case brightness(Float)
    var id: String {
        switch self {
        case .headphones(let h, _): return "hp-\(h.name)"
        case .charging: return "charging"
        case .volume: return "volume"
        case .brightness: return "brightness"
        }
    }
}

// Tout ce qui vit autour de la musique : batterie, sortie audio (AirPods), météo, notifications.
final class Devices: ObservableObject {
    @Published var battery: (percent: Int, charging: Bool)? { didSet {} }
    @Published var headphones: Headphones?
    @Published var volume: Float?
    @Published var weather: Weather?
    @Published var toast: Toast?

    private let q = DispatchQueue(label: "osa.devices", qos: .utility)
    private var toastTimer: Timer?
    private var outputDevice: AudioDeviceID = 0
    private var weatherTimer: Timer?, hpTimer: Timer?
    private var lastLocation: (lat: Double, lon: Double, city: String)?
    private var lastCity = ""
    private var powerTokens: [Int32] = []
    private var brightnessTimer: Timer?
    private var lastBrightness: Float = -1
    private var muted = false
    private var brightnessKeyUntil: TimeInterval = 0
    private var keyMonitor: Any?

    func start() {
        readBattery(initial: true)
        // Notification IOKit : appelée à chaque branchement / débranchement / variation.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Devices>.fromOpaque(ctx).takeUnretainedValue().readBattery(initial: false)
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        // Second canal (notify) : certains Mac n'envoient la notification IOKit qu'une fois sur deux.
        for name in [kIOPSNotifyPowerSource, kIOPSNotifyAttach, kIOPSNotifyAnyPowerSource] {
            var token: Int32 = 0
            if notify_register_dispatch(name, &token, .main, { [weak self] _ in self?.readBattery(initial: false) }) == NOTIFY_STATUS_OK {
                powerTokens.append(token)
            }
        }
        startBrightness()
        watchOutput()
        refreshWeather()
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refreshWeather() }
        // Batterie du casque : relue de temps en temps tant qu'il est connecté.
        hpTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            guard let self, self.headphones != nil else { return }
            self.readHeadphoneBattery(announce: false)
        }
    }

    func show(_ t: Toast, for seconds: TimeInterval = 5) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { toast = t }
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { self?.toast = nil }
        }
    }

    // MARK: Batterie du Mac
    private func readBattery(initial: Bool) {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey as String] as? Int else { continue }
            let charging = (d[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
            DispatchQueue.main.async {
                let was = self.battery?.charging
                if was != charging || self.battery?.percent != cap { self.battery = (cap, charging) }
                if !initial, charging, was == false {
                    log.notice("secteur branché (\(cap) %)")
                    if Prefs.shared.showCharging { self.show(.charging(cap), for: 4) }
                }
            }
            return
        }
    }

    // MARK: Sortie audio (CoreAudio) — repère l'arrivée d'un casque Bluetooth
    private func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func watchOutput() {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.outputChanged(announce: true)
        }
        outputChanged(announce: false)
    }

    private func outputChanged(announce: Bool) {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return }
        if id != outputDevice {
            outputDevice = id
            var va = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(id, &va, .main) { [weak self] _, _ in
                guard let self, id == self.outputDevice else { return }
                self.volumeChanged()
            }
            var ma = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(id, &ma, .main) { [weak self] _, _ in
                guard let self, id == self.outputDevice else { return }
                self.volumeChanged()
            }
        }
        volume = readVolume(id)
        muted = readMute(id)
        var transport: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        var ta = addr(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &ta, 0, nil, &size, &transport)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        if bluetooth {
            let name = deviceName(id) ?? "Casque"
            headphones = Headphones(name: name)
            if announce, Prefs.shared.showAirpods { show(.headphones(headphones!, volume: volume)) }
            readHeadphoneBattery(announce: announce)
        } else {
            headphones = nil
        }
    }

    /// Le volume (ou la sourdine) vient de changer : pastille, ou mise à jour de celle du casque.
    private func volumeChanged() {
        let v = readVolume(outputDevice), m = readMute(outputDevice)
        guard v != volume || m != muted else { return }
        volume = v; muted = m
        guard let v else { return }
        if case .headphones(let h, _) = toast { toast = .headphones(h, volume: m ? 0 : v); show(toast!, for: 2.5); return }
        guard Prefs.shared.showVolume else { return }
        let sym = headphones.map { HeadphoneGlyph.symbol($0.name) }
        show(.volume(v, muted: m, symbol: sym ?? Self.speakerSymbol(v, muted: m)), for: 1.8)
    }

    static func speakerSymbol(_ v: Float, muted: Bool) -> String {
        if muted || v < 0.01 { return "speaker.slash.fill" }
        return v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private func readMute(_ id: AudioDeviceID) -> Bool {
        var v = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return false }
        return v != 0
    }

    // MARK: Luminosité (écran intégré, framework privé DisplayServices)
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let getBrightness: GetBrightness? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightness.self)
    }()

    /// Aucune notification publique n'existe pour la luminosité : lecture 5 fois par seconde
    /// (un appel C, coût négligeable). La pastille n'apparaît que juste après un appui sur
    /// F1/F2 (sinon l'auto-luminosité en déclencherait sans arrêt).
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    private func startBrightness() {
        guard Self.getBrightness != nil else { return }
        // Touches spéciales (évènements « system-defined », sous-type 8) : 2 = plus lumineux, 3 = moins.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] e in
            guard e.subtype.rawValue == 8 else { return }
            let key = (e.data1 & 0xFFFF0000) >> 16
            if key == 2 || key == 3 { self?.brightnessKeyUntil = Date.timeIntervalSinceReferenceDate + 1.2 }
        }
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.pollBrightness() }
        brightnessTimer?.tolerance = 0.05
        pollBrightness()
    }

    private func pollBrightness() {
        var b: Float = 0
        guard let fn = Self.getBrightness, fn(CGMainDisplayID(), &b) == 0, (0...1).contains(b) else { return }
        defer { lastBrightness = b }
        guard lastBrightness >= 0, abs(b - lastBrightness) > 0.002,
              Date.timeIntervalSinceReferenceDate < brightnessKeyUntil else { return }
        if Prefs.shared.showBrightness { show(.brightness(b), for: 1.8) }
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString; var size = UInt32(MemoryLayout<CFString>.size)
        var a = addr(kAudioObjectPropertyName)
        let st = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return st == noErr ? name as String : nil
    }

    private func readVolume(_ id: AudioDeviceID) -> Float? {
        var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    /// Niveaux de batterie du casque, lus dans system_profiler (le Bluetooth met
    /// parfois quelques secondes à les publier après la connexion → 2 essais).
    private func readHeadphoneBattery(announce: Bool, attempt: Int = 0) {
        guard let name = headphones?.name else { return }
        q.async {
            let out = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType"], timeout: 10) ?? ""
            let found = Self.parseBluetooth(out, prefer: name)
            DispatchQueue.main.async {
                guard self.headphones?.name == name else { return }
                if let f = found {
                    var h = self.headphones!
                    h.left = f.left; h.right = f.right; h.caseLevel = f.caseLevel; h.level = f.level
                    self.headphones = h
                    if case .headphones = self.toast { self.toast = .headphones(h, volume: self.volume) }
                } else if attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.readHeadphoneBattery(announce: announce, attempt: attempt + 1) }
                }
            }
        }
    }

    static func parseBluetooth(_ out: String, prefer: String) -> Headphones? {
        var devices: [Headphones] = []
        var cur: Headphones?
        func flush() { if let c = cur, c.left != nil || c.right != nil || c.level != nil { devices.append(c) } }
        for raw in out.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") && indent >= 8 && indent <= 14 && !line.contains("Bluetooth") {
                flush(); cur = Headphones(name: String(line.dropLast()))
            } else if cur != nil {
                func num(_ key: String) -> Int? {
                    guard line.hasPrefix(key) else { return nil }
                    return Int(line.dropFirst(key.count).replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
                }
                if let v = num("Left Battery Level:") { cur!.left = v }
                else if let v = num("Right Battery Level:") { cur!.right = v }
                else if let v = num("Case Battery Level:") { cur!.caseLevel = v }
                else if let v = num("Battery Level:") { cur!.level = v }
            }
        }
        flush()
        return devices.first { $0.name == prefer } ?? devices.first
    }

    // MARK: Météo (Open-Meteo, gratuit et sans clé)
    func refreshWeather() {
        let city = Prefs.shared.city.trimmingCharacters(in: .whitespaces)
        q.async {
            func json(_ s: String) -> [String: Any]? {
                guard let u = URL(string: s), let d = try? Data(contentsOf: u) else { return nil }
                return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            }
            if self.lastLocation == nil || city != self.lastCity {
                if !city.isEmpty {
                    let enc = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let r = (json("https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=1&language=fr")?["results"] as? [[String: Any]])?.first,
                       let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double {
                        self.lastLocation = (lat, lon, r["name"] as? String ?? city)
                    }
                } else if let j = json("https://ipapi.co/json/"), let lat = j["latitude"] as? Double, let lon = j["longitude"] as? Double {
                    // Position approximative déduite de l'adresse IP (aucune permission demandée).
                    self.lastLocation = (lat, lon, j["city"] as? String ?? "")
                }
                self.lastCity = city
            }
            guard let loc = self.lastLocation,
                  let cur = json("https://api.open-meteo.com/v1/forecast?latitude=\(loc.lat)&longitude=\(loc.lon)&current=temperature_2m,weather_code,is_day")?["current"] as? [String: Any],
                  let t = cur["temperature_2m"] as? Double, let code = cur["weather_code"] as? Int else { return }
            let w = Weather(temp: Int(t.rounded()), code: code, isDay: (cur["is_day"] as? Int ?? 1) == 1, city: loc.city)
            DispatchQueue.main.async { self.weather = w }
        }
    }

    static func symbol(_ w: Weather) -> String {
        switch w.code {
        case 0: return w.isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return w.isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return w.isDay ? "cloud.sun.rain.fill" : "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
