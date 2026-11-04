//
//  PomodoroWaveView.swift
//  boringNotch
//

import SwiftUI

/// The "time's up" screen: layered accent-coloured waves rolling across a black background.
struct PomodoroWaveView: View {
    let title: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let layers = 4
                    for i in 0..<layers {
                        let f = Double(i) / Double(layers)
                        var path = Path()
                        let baseline = size.height * (0.55 + 0.1 * f)
                        let amp = size.height * (0.16 - 0.025 * f)
                        let phase = t * (1.6 + f) + f * 2
                        path.move(to: CGPoint(x: 0, y: size.height))
                        var x: CGFloat = 0
                        while x <= size.width {
                            let y = baseline + sin(x / size.width * .pi * (2.2 + f) + phase) * amp
                            path.addLine(to: CGPoint(x: x, y: y))
                            x += 4
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                        ctx.fill(path, with: .color(Color.effectiveAccent.opacity(0.18 + 0.2 * (1 - f))))
                    }
                }
            }
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.effectiveAccent)
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.effectiveAccent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
