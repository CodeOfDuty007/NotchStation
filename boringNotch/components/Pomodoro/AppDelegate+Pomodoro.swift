//
//  AppDelegate+Pomodoro.swift
//  boringNotch
//

import Defaults
import SwiftUI

extension AppDelegate {
    /// Registered once at launch: flash the notch whenever a Pomodoro phase ends.
    func setupPomodoroAlarmObserver() {
        NotificationCenter.default.addObserver(forName: .pomodoroTimeUp, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.flashNotchForPomodoro() }
        }
    }

    /// Muted: opens and closes the notch rapidly on every screen, then leaves it open on the
    /// Pomodoro tab (wave screen) until dismissed. Unmuted: the looping sound is the alert, so
    /// the notch just opens once, with no strobing, so Dismiss is within reach. Abandons itself
    /// if the alarm is dismissed or superseded, and never closes a notch the user has since used.
    @MainActor
    func flashNotchForPomodoro() {
        let models = viewModels.isEmpty ? [vm] : Array(viewModels.values)
        let coordinator = BoringViewCoordinator.shared
        let manager = PomodoroManager.shared
        let generation = manager.alarmGeneration
        let cycles = Defaults[.pomodoroMuted] ? 8 : 0

        Task { @MainActor in
            @MainActor func stillCurrent() -> Bool { manager.isAlarming && manager.alarmGeneration == generation }
            @MainActor func setOpen(_ open: Bool) {
                for model in models {
                    withAnimation(model.animation) {
                        if open { model.open() } else { model.close() }
                    }
                }
                // `close()` falls back to the Home tab; keep the alarm tab selected.
                coordinator.currentView = .pomodoro
            }

            coordinator.currentView = .pomodoro
            for _ in 0..<cycles {
                guard stillCurrent() else { return }
                setOpen(true)
                try? await Task.sleep(for: .milliseconds(300))
                guard stillCurrent() else { return }
                setOpen(false)
                try? await Task.sleep(for: .milliseconds(250))
            }
            if stillCurrent() { setOpen(true) }
        }
    }
}
