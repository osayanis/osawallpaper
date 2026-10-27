import AppKit
import Combine
import IOKit.pwr_mgt
import os

// Garde l'écran allumé un moment sur l'écran verrouillé : macOS l'éteint très vite quand le Mac
// est verrouillé, avant qu'on ait eu le temps de profiter du fond ou de la pochette. Le délai
// (Réglages → Écran verrouillé) repart à chaque mouvement de souris ou touche ; ensuite macOS
// reprend la main et éteint l'écran comme d'habitude. Rien en mode économie d'énergie.
final class ScreenAwake {
    private let lock: LockState
    private let prefs: Prefs
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private let log = Logger(subsystem: "com.osalabs.osawallpaper", category: "awake")

    init(lock: LockState, prefs: Prefs) {
        self.lock = lock
        self.prefs = prefs
        lock.$locked.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &bag)
        prefs.$lockAwakeMinutes.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &bag)
    }

    deinit { release() }

    /// Test sans verrouiller : garde l'assertion `seconds` secondes.
    func test(seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.hold() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds) { [weak self] in self?.release() }
    }

    private func update() {
        timer?.invalidate(); timer = nil
        let minutes = prefs.lockAwakeMinutes
        guard lock.locked, prefs.lockScreen, minutes > 0, !ProcessInfo.processInfo.isLowPowerModeEnabled else { release(); return }
        hold()
        // Toutes les 10 s : encore une activité récente ? sinon on rend la main à macOS.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            if idle >= Double(minutes) * 60 { self.release() } else { self.hold() }
        }
    }

    private func hold() {
        guard assertion == 0 else { return }
        let ok = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "OsaWallpaper : écran verrouillé affiché" as CFString, &assertion)
        if ok != kIOReturnSuccess { assertion = 0 }
        log.notice("écran gardé allumé (\(self.prefs.lockAwakeMinutes, privacy: .public) min) : \(ok == kIOReturnSuccess, privacy: .public)")
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        log.notice("écran rendu à macOS")
    }
}
