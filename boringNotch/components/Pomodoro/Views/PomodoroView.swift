//
//  PomodoroView.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Notch tab for the Pomodoro timer: a work timer and a rest timer (tap either time to edit it),
/// one ring showing the running countdown, and a mute/unmute button in the bottom-right that
/// chooses between a looping alarm sound and a silent visual alert.
struct PomodoroView: View {
    @StateObject private var timer = PomodoroManager.shared
    @Default(.pomodoroMuted) private var muted
    @Default(.pomodoroSoundName) private var soundName
    @Default(.pomodoroWorkSeconds) private var workSeconds
    @Default(.pomodoroRestSeconds) private var restSeconds

    @State private var editing: PomodoroManager.Phase?

    var body: some View {
        ZStack {
            if timer.isAlarming {
                PomodoroWaveView(
                    title: timer.phase == .work ? "Time to rest" : "Back to work",
                    onDismiss: { timer.dismissAlarm() }
                )
            } else {
                HStack(spacing: 22) {
                    phaseCard(.work, seconds: workSeconds)
                    ring
                    phaseCard(.rest, seconds: restSeconds)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .disabled(editing != nil)
            }

            if let phase = editing {
                PomodoroTimeEditor(
                    title: phase == .work ? "Work time" : "Rest time",
                    initialSeconds: phase == .work ? workSeconds : restSeconds,
                    onDone: { seconds in
                        timer.setDuration(seconds, for: phase)
                        editing = nil
                    },
                    onCancel: { editing = nil }
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .bottomTrailing) { soundControls.padding(8) }
        .animation(.smooth(duration: 0.25), value: editing)
        .animation(.smooth(duration: 0.25), value: timer.isAlarming)
    }

    // MARK: Pieces

    private func phaseCard(_ phase: PomodoroManager.Phase, seconds: Int) -> some View {
        let active = timer.phase == phase
        return VStack(spacing: 4) {
            // Tap the label to choose which timer is the active one (work or rest).
            Button {
                guard !active else { return }
                timer.switchPhase(to: phase)
            } label: {
                Text(phase == .work ? "WORK" : "REST")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(active ? Color.white : .gray)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(active ? Color.effectiveAccent : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(active ? "Active timer" : "Switch to the \(phase == .work ? "work" : "rest") timer")
            Button {
                guard timer.canEditDurations else { return }
                editing = phase
            } label: {
                Text(PomodoroTimeFormat.display(TimeInterval(seconds)))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(active ? 0.14 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.effectiveAccent.opacity(active ? 0.9 : 0), lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .help(timer.canEditDurations ? "Click to change" : "Pause the timer to change it")
            .opacity(timer.canEditDurations || active ? 1 : 0.8)
        }
        .frame(width: 130)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(Color.effectiveAccent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text(PomodoroTimeFormat.display(timer.remaining))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                HStack(spacing: 10) {
                    circleButton(timer.runState == .running ? "pause.fill" : "play.fill", prominent: true) {
                        timer.toggleRun()
                    }
                    circleButton("arrow.counterclockwise", prominent: false) { timer.reset() }
                    circleButton("forward.end.fill", prominent: false) { timer.switchPhase() }
                }
            }
        }
        .frame(width: 118, height: 118)
    }

    private func circleButton(_ symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 12 : 10, weight: .bold))
                .foregroundStyle(prominent ? Color.white : Color.gray)
                .frame(width: prominent ? 26 : 20, height: prominent ? 26 : 20)
                .background(Circle().fill(prominent ? Color.effectiveAccent : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    /// Bottom-right: mute/unmute, plus a menu to choose which system sound the alarm loops.
    private var soundControls: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(PomodoroManager.availableSounds, id: \.self) { name in
                    Button {
                        soundName = name
                        timer.previewSound(named: name)
                    } label: {
                        if name == soundName { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.gray)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Alarm sound")

            Button {
                muted.toggle()
                timer.muteChanged(muted)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(muted ? Color.gray : Color.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(muted ? Color.white.opacity(0.1) : Color.effectiveAccent))
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute: play a loud alarm when time is up" : "Mute: flash the notch instead of playing a sound")
        }
    }
}
