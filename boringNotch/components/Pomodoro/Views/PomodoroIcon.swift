//
//  PomodoroIcon.swift
//  boringNotch
//

import SwiftUI

/// A flat, single-colour take on the speeding-stopwatch artwork (crown, ring, "L" hands and
/// motion lines). Drawn as shapes rather than a bitmap so it picks up the tab bar's
/// selected/unselected foreground style at any size.
struct PomodoroIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = s * 0.11
            ZStack {
                // Speed lines, trailing off the left of the clock face.
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .frame(width: s * [0.30, 0.22, 0.27][i], height: lw * 0.85)
                        .position(x: s * [0.14, 0.18, 0.15][i], y: s * [0.30, 0.52, 0.74][i])
                }
                // Crown.
                RoundedRectangle(cornerRadius: lw * 0.3)
                    .frame(width: s * 0.17, height: s * 0.12)
                    .position(x: s * 0.66, y: s * 0.07)
                // Case.
                Circle()
                    .stroke(lineWidth: lw)
                    .frame(width: s * 0.58, height: s * 0.58)
                    .position(x: s * 0.66, y: s * 0.55)
                // "L"-shaped hands.
                Path { p in
                    p.move(to: CGPoint(x: s * 0.60, y: s * 0.40))
                    p.addLine(to: CGPoint(x: s * 0.60, y: s * 0.58))
                    p.addLine(to: CGPoint(x: s * 0.76, y: s * 0.58))
                }
                .stroke(style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview {
    PomodoroIcon().frame(width: 64, height: 64).foregroundStyle(.blue).padding()
}
