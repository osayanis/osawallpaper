import SwiftUI
import AppKit
import Combine
import SkyLightWindow

// Fenêtres d'OsaWallpaper :
//  • une fenêtre « écran verrouillé » par écran, placée dans un espace SkyLight
//    plus haut que l'écran de verrouillage. Invisible tant que le Mac est
//    déverrouillé ; visible verrouillé, quand un morceau joue.
//  • une fenêtre de notification (AirPods, charge) au-dessus de tout, partout :
//    apps, plein écran, écran verrouillé.
// Les clics traversent ces fenêtres partout sauf sur les zones `hitZone()`.
// Elles ne deviennent jamais « clé » : le mot de passe tapé va toujours à macOS.

final class HitStore { var rects: [CGRect] = [] }

/// Position du curseur relative à l'écran (0…1), pour l'effet de relief de la pochette.
final class CursorModel: ObservableObject { @Published var p = CGPoint(x: 0.5, y: 0.5) }

/// État partagé : verrouillé ou non, aperçu demandé.
final class LockState: ObservableObject {
    @Published var locked = false
    @Published var preview = false
    var visible: Bool { locked || preview }
}

struct HitKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
extension View {
    /// Déclare la vue comme zone cliquable de sa fenêtre.
    func hitZone() -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HitKey.self, value: [g.frame(in: .global)]) })
    }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        canBecomeVisibleWithoutLogin = true
        level = .screenSaver
        setFrame(frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// En mode démo, la fenêtre reste au niveau du bureau (derrière tes apps) pour les captures de test.
    func lift() {
        orderFrontRegardless()
        if Demo.on {
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        } else {
            SkyLightOperator.shared.delegateWindow(self)
        }
    }
}

enum Demo { static let on = ProcessInfo.processInfo.environment["OSAWALLPAPER_DEMO"] != nil }

/// Fenêtre « écran verrouillé » d'un écran.
final class LockWindow {
    let screen: NSScreen
    let panel: OverlayPanel
    let hits = HitStore()
    let cursor = CursorModel()

    init(screen: NSScreen, music: MusicWatcher, devices: Devices, prefs: Prefs, lock: LockState) {
        self.screen = screen
        panel = OverlayPanel(frame: screen.frame)
        let size = screen.frame.size
        let top = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        let hits = self.hits
        panel.contentView = FirstMouseHostingView(rootView:
            LockView(music: music, devices: devices, prefs: prefs, lock: lock, cursor: cursor, size: size, topInset: top)
                .frame(width: size.width, height: size.height)
                .onPreferenceChange(HitKey.self) { hits.rects = $0 })
        panel.lift()
    }

    func close() { panel.orderOut(nil); panel.close() }

    func track(_ mouse: NSPoint, active: Bool) {
        let f = panel.frame
        guard active, f.contains(mouse) else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let p = CGPoint(x: mouse.x - f.minX, y: f.maxY - mouse.y)
        let over = hits.rects.contains { $0.insetBy(dx: -4, dy: -4).contains(p) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        let rel = CGPoint(x: p.x / f.width, y: p.y / f.height)
        if abs(rel.x - cursor.p.x) > 0.004 || abs(rel.y - cursor.p.y) > 0.004 { cursor.p = rel }
    }
}

final class ScreenManager {
    let lock = LockState()
    private let music: MusicWatcher, devices: Devices, prefs: Prefs
    private var windows: [LockWindow] = []
    private var toastPanel: OverlayPanel?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var lastMouse = NSPoint(x: -1, y: -1)
    private var previewTimer: Timer?

    init(music: MusicWatcher, devices: Devices, prefs: Prefs) {
        self.music = music; self.devices = devices; self.prefs = prefs
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.rebuild() }
        }
        // Verrouillage / déverrouillage de la session.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setLocked(true) }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setLocked(false) }
        lock.locked = Self.sessionLocked()

        prefs.$allScreens.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }.store(in: &bag)
        devices.$toast.sink { [weak self] t in if t != nil { DispatchQueue.main.async { self?.placeToast() } } }.store(in: &bag)
    }

    static func sessionLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func setLocked(_ v: Bool) {
        lock.locked = v
        if v { music.poll(); windows.forEach { $0.panel.lift() } }   // reprend sa place au-dessus de l'écran verrouillé
        lastMouse = NSPoint(x: -1, y: -1)
    }

    /// Montre l'écran verrouillé quelques secondes sans verrouiller le Mac.
    func showPreview(seconds: TimeInterval = 8) {
        lock.preview = true
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.lock.preview = false }
    }
    func endPreview() { previewTimer?.invalidate(); lock.preview = false }

    func rebuild() {
        windows.forEach { $0.close() }
        let main = NSScreen.screens.first
        let screens = prefs.allScreens ? NSScreen.screens : [main].compactMap { $0 }
        windows = screens.map { LockWindow(screen: $0, music: music, devices: devices, prefs: prefs, lock: lock) }
        if toastPanel == nil {
            let p = OverlayPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
            p.contentView = NSHostingView(rootView: ToastHost(devices: devices).frame(width: 420, height: 110))
            toastPanel = p
        }
        placeToast()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
        }
        lastMouse = NSPoint(x: -1, y: -1)
    }

    /// La notification apparaît en haut de l'écran où se trouve la souris.
    private func placeToast() {
        guard let p = toastPanel else { return }
        let m = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main else { return }
        let top = max(s.frame.maxY - s.visibleFrame.maxY, s.safeAreaInsets.top)
        p.setFrame(NSRect(x: s.frame.midX - 210, y: s.frame.maxY - top - 110 - 2, width: 420, height: 110), display: true)
        p.lift()
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        if m == lastMouse { return }
        lastMouse = m
        let active = lock.visible && prefs.lockScreen && music.music != nil
        windows.forEach { $0.track(m, active: active) }
    }
}
