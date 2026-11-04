//
//  PomodoroManager.swift
//  boringNotch
//

import AppKit
import Combine
import Defaults
import SwiftUI

extension Notification.Name {
    /// Posted when a Pomodoro phase finishes; `AppDelegate` flashes the notch in response.
    static let pomodoroTimeUp = Notification.Name("pomodoroTimeUp")
}

/// Owns the Pomodoro state. It is a singleton (not owned by the tab's view) because the timer
/// must keep running - and the alarm must fire - while the notch is closed or on another tab.
/// The countdown is derived from an absolute end `Date`, so it doesn't drift and survives sleep.
@MainActor
final class PomodoroManager: ObservableObject {
    static let shared = PomodoroManager()

    enum Phase { case work, rest
        var other: Phase { self == .work ? .rest : .work }
    }
    enum RunState { case idle, running, paused, alarming }

    /// Names of the system alert sounds in /System/Library/Sounds (the Clock app's own tones
    /// are not readable from the sandbox).
    static let availableSounds: [String] = {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let names = files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        return names.isEmpty ? ["Hero"] : names
    }()

    /// Safety net so an unattended alarm doesn't loop forever.
    private static let maxAlarmDuration: TimeInterval = 60

    @Published private(set) var phase: Phase = .work
    @Published private(set) var runState: RunState = .idle
    @Published private(set) var remaining: TimeInterval = TimeInterval(PomodoroTimeFormat.clamp(Defaults[.pomodoroWorkSeconds]))

    private var endDate: Date?
    private var ticker: Timer?
    private var sound: NSSound?
    private var alarmStopTask: Task<Void, Never>?
    private var previewSound: NSSound?
    /// True once the 60s cap has silenced this alarm; unmuting must not restart a sound that
    /// nothing would stop again.
    private var alarmSoundExpired = false
    /// Bumps for every alarm so a stale notch-flash task can tell it has been superseded.
    private(set) var alarmGeneration = 0

    private init() {}

    var phaseDuration: TimeInterval { duration(for: phase) }
    var progress: Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / phaseDuration))
    }
    var isAlarming: Bool { runState == .alarming }
    /// Durations can be edited whenever a countdown isn't actively in progress.
    var canEditDurations: Bool { runState != .running && runState != .alarming }

    func duration(for phase: Phase) -> TimeInterval {
        TimeInterval(PomodoroTimeFormat.clamp(phase == .work ? Defaults[.pomodoroWorkSeconds] : Defaults[.pomodoroRestSeconds]))
    }

    // MARK: Controls

    func toggleRun() {
        switch runState {
        case .idle, .paused: start()
        case .running: pause()
        case .alarming: dismissAlarm()
        }
    }

    func start() {
        guard runState == .idle || runState == .paused else { return }
        if remaining <= 0 { remaining = phaseDuration }
        endDate = Date().addingTimeInterval(remaining)
        runState = .running
        startTicker()
    }

    func pause() {
        guard runState == .running else { return }
        updateRemaining()
        // Pausing right at the deadline must not swallow the alarm.
        if remaining <= 0 { timeUp(); return }
        stopTicker()
        endDate = nil
        runState = .paused
    }

    /// Back to the full length of the current phase, stopped.
    func reset() {
        if runState == .alarming { stopAlarm() }
        stopTicker()
        endDate = nil
        runState = .idle
        remaining = phaseDuration
    }

    /// Jump to the other phase (stopped), e.g. to start resting early.
    func switchPhase(to newPhase: Phase? = nil) {
        if runState == .alarming { stopAlarm() }
        stopTicker()
        endDate = nil
        phase = newPhase ?? phase.other
        runState = .idle
        remaining = phaseDuration
    }

    func setDuration(_ seconds: Int, for target: Phase) {
        let clamped = PomodoroTimeFormat.clamp(seconds)
        let unchanged = clamped == Int(duration(for: target))
        switch target {
        case .work: Defaults[.pomodoroWorkSeconds] = clamped
        case .rest: Defaults[.pomodoroRestSeconds] = clamped
        }
        // Re-sync the visible countdown if the edited phase is the current, untouched one.
        if !unchanged, target == phase, runState == .idle || runState == .paused {
            remaining = TimeInterval(clamped)
            runState = .idle
        }
    }

    /// Stops the alarm and queues up the next phase, ready to start.
    func dismissAlarm() {
        guard runState == .alarming else { return }
        stopAlarm()
        phase = phase.other
        runState = .idle
        remaining = phaseDuration
    }

    // MARK: Sound

    func previewSound(named name: String) {
        guard !Defaults[.pomodoroMuted] else { return }
        previewSound?.stop()
        previewSound = Self.makeSound(named: name)
        previewSound?.loops = false
        previewSound?.volume = 1.0
        previewSound?.play()
    }

    // MARK: Internals

    /// A fresh instance per use: `NSSound(named:)` hands back a shared object, so setting
    /// `loops` on it would leak into every later preview.
    private static func makeSound(named name: String) -> NSSound? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return NSSound(contentsOf: url, byReference: false)
            ?? NSSound(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/Hero.aiff"), byReference: false)
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func updateRemaining() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
    }

    private func tick() {
        guard runState == .running else { return }
        updateRemaining()
        if remaining <= 0 { timeUp() }
    }

    private func timeUp() {
        stopTicker()
        endDate = nil
        remaining = 0
        runState = .alarming
        alarmGeneration += 1
        alarmSoundExpired = false
        startAlarmSound()
        NotificationCenter.default.post(name: .pomodoroTimeUp, object: nil)
        alarmStopTask?.cancel()
        alarmStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxAlarmDuration))
            guard !Task.isCancelled else { return }
            // Stop the noise, but keep the alarm state so the user still sees time is up.
            self?.alarmSoundExpired = true
            self?.sound?.stop()
            self?.sound = nil
        }
    }

    private func startAlarmSound() {
        guard !Defaults[.pomodoroMuted] else { return }
        sound?.stop()
        let chosen = Self.makeSound(named: Defaults[.pomodoroSoundName])
        chosen?.loops = true
        chosen?.volume = 1.0 // full app volume; the system output volume is never touched
        chosen?.play()
        sound = chosen
    }

    private func stopAlarm() {
        alarmStopTask?.cancel()
        alarmStopTask = nil
        sound?.stop()
        sound = nil
    }

    /// Muting during an alarm silences it immediately; unmuting doesn't restart it.
    func muteChanged(_ muted: Bool) {
        if muted { sound?.stop(); sound = nil }
        else if runState == .alarming, sound == nil, !alarmSoundExpired { startAlarmSound() }
    }
}
