//
//  PomodoroMiniBar.swift
//  boringNotch
//

import SwiftUI

/// A small bar that slides out from behind the left edge of the *closed* notch while a Pomodoro
/// countdown is running or paused, so the time left is visible without opening the notch. It
/// shows the remaining time of whichever phase (work or rest) is active, with a thin accent
/// progress line along the bottom. Tapping it opens the notch on the Pomodoro tab.
///
/// This host is the only thing in `ContentView` that observes the timer: the countdown ticks
/// several times a second and shouldn't invalidate the whole notch view.
struct PomodoroMiniBarHost: View {
    @ObservedObject private var timer = PomodoroManager.shared

    let isClosed: Bool
    /// Width of the closed notch as currently drawn (it widens for some live activities).
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let onTap: () -> Void

    @State private var stableWidth: CGFloat?

    private let barWidth: CGFloat = 80
    /// How far the bar tucks under the notch, so it looks like it comes out of it.
    private let tuck: CGFloat = 10

    private var anchorWidth: CGFloat { visible ? notchWidth : (stableWidth ?? notchWidth) }

    private var visible: Bool {
        isClosed
            // Very small configured heights would leave no room for a legible bar.
            && notchHeight > 12
            // The battery notification stretches the notch across the whole window; stay out.
            && notchWidth < 500
            && (timer.runState == .running || timer.runState == .paused)
    }

    var body: some View {
        bar
            .scaleEffect(x: visible ? 1 : 0.01, anchor: .trailing)
            .opacity(visible ? 1 : 0)
            .offset(x: -(anchorWidth / 2 + barWidth / 2 - tuck))
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: visible)
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: anchorWidth)
            // Remember the last width the bar was actually shown against, so it retracts back
            // into the notch it came out of even if the notch stretches as it hides.
            .onChange(of: notchWidth, initial: true) { _, new in if visible { stableWidth = new } }
            .onChange(of: visible) { _, now in if now { stableWidth = notchWidth } }
            .allowsHitTesting(visible)
    }

    private var bar: some View {
        let height = max(0, notchHeight - 6)
        return HStack(spacing: 5) {
            PomodoroIcon()
                .frame(width: 12, height: 12)
            Text(PomodoroTimeFormat.display(timer.remaining))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Color.effectiveAccent)
        .opacity(timer.runState == .paused ? 0.55 : 1)
        .padding(.trailing, tuck)
        .frame(width: barWidth, height: height)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 0, topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
        )
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.effectiveAccent)
                    .frame(width: max(0, (geo.size.width - 12) * timer.progress), height: 2)
                    .padding(.leading, 8)
                    .offset(y: geo.size.height - 3)
            }
            .opacity(timer.runState == .paused ? 0.4 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help("Pomodoro — click to open")
    }
}
