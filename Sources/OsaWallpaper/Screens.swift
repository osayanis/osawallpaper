import SwiftUI
import AppKit
import Combine

// Deux fenêtres par écran :
//  • le FOND, au niveau du bureau (sous les icônes du Finder) : pochette floutée ;
//  • les WIDGETS, juste au-dessus des icônes mais sous toutes les fenêtres d'apps.
// La fenêtre des widgets laisse passer les clics partout, sauf sur les zones
// interactives (boutons, carte musique) : on bascule `ignoresMouseEvents`
// selon la position du curseur, comme l'îlot d'OsaNotch.

final class HitStore { var rects: [CGRect] = [] }

/// Position du curseur relative à l'écran (0…1), pour l'effet de relief de la pochette.
final class CursorModel: ObservableObject { @Published var p = CGPoint(x: 0.5, y: 0.5) }

struct HitKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
extension View {
    /// Déclare la vue comme zone cliquable de la fenêtre des widgets.
    func hitZone() -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HitKey.self, value: [g.frame(in: .global)]) })
    }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DesktopPanel: NSPanel {
    init(screen: NSScreen, level: CGWindowLevelKey, offset: Int = 0) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(level)) + offset)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ScreenSet {
    let screen: NSScreen
    let background: DesktopPanel
    let widgets: DesktopPanel
    let hits = HitStore()
    let cursor = CursorModel()

    init(screen: NSScreen, music: MusicWatcher, devices: Devices, prefs: Prefs, isMain: Bool) {
        self.screen = screen
        background = DesktopPanel(screen: screen, level: .desktopWindow)
        widgets = DesktopPanel(screen: screen, level: .desktopIconWindow, offset: 1)

        let insets = EdgeInsets(
            top: screen.frame.maxY - screen.visibleFrame.maxY,
            leading: 0,
            bottom: screen.visibleFrame.minY - screen.frame.minY,
            trailing: 0)
        let size = screen.frame.size

        background.contentView = NSHostingView(rootView: BackgroundView(music: music, prefs: prefs).frame(width: size.width, height: size.height))
        let hits = self.hits
        widgets.contentView = FirstMouseHostingView(rootView:
            WidgetsView(music: music, devices: devices, prefs: prefs, cursor: cursor, size: size, insets: insets, isMain: isMain)
                .frame(width: size.width, height: size.height)
                .onPreferenceChange(HitKey.self) { hits.rects = $0 })
        background.orderFront(nil)
        widgets.orderFront(nil)
    }

    func close() { background.orderOut(nil); widgets.orderOut(nil); background.close(); widgets.close() }

    /// Appelé ~20×/s : clics laissés au bureau sauf au-dessus d'une zone interactive.
    func track(_ mouse: NSPoint) {
        let f = widgets.frame
        guard f.contains(mouse) else {
            if !widgets.ignoresMouseEvents { widgets.ignoresMouseEvents = true }
            return
        }
        let p = CGPoint(x: mouse.x - f.minX, y: f.maxY - mouse.y)
        let over = hits.rects.contains { $0.insetBy(dx: -4, dy: -4).contains(p) }
        if widgets.ignoresMouseEvents == over { widgets.ignoresMouseEvents = !over }
        let rel = CGPoint(x: p.x / f.width, y: p.y / f.height)
        if abs(rel.x - cursor.p.x) > 0.004 || abs(rel.y - cursor.p.y) > 0.004 { cursor.p = rel }
    }
}

final class ScreenManager {
    private let music: MusicWatcher, devices: Devices, prefs: Prefs
    private var sets: [ScreenSet] = []
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var lastMouse = NSPoint(x: -1, y: -1)

    init(music: MusicWatcher, devices: Devices, prefs: Prefs) {
        self.music = music; self.devices = devices; self.prefs = prefs
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // Les écrans se réorganisent souvent en plusieurs étapes → petit délai.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.rebuild() }
        }
        prefs.$allScreens.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }.store(in: &bag)
    }

    func rebuild() {
        sets.forEach { $0.close() }
        let main = NSScreen.screens.first   // l'écran qui porte la barre de menus
        let screens = prefs.allScreens ? NSScreen.screens : [main].compactMap { $0 }
        sets = screens.map { ScreenSet(screen: $0, music: music, devices: devices, prefs: prefs, isMain: $0 == main) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
        }
        lastMouse = NSPoint(x: -1, y: -1)
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        if m == lastMouse { return }
        lastMouse = m
        sets.forEach { $0.track(m) }
    }
}
