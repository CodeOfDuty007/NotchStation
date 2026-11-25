//
//  DuckSpriteView.swift
//  boringNotch
//

import SwiftUI

/// Animation state for the duck sprite; the overlay controller mutates it every frame.
@MainActor
final class DuckModel: ObservableObject {
    @Published var facingLeft = false
    /// Alternates 0/1 while walking so the feet take turns lifting.
    @Published var footPhase = 0
    /// 0 = beak at rest, 1 = fully extended toward the target.
    @Published var beak: CGFloat = 0
    @Published var leanDegrees: Double = 0
    @Published var bob: CGFloat = 0
    @Published var opacity: Double = 1
    @Published var scale: CGFloat = 1
}

/// The round orange duck from the design schema, drawn with shapes (outline #261204, body
/// gradient #FFAE2B -> #F69C19 -> #C96707, cream highlight, vertical-oval eye, extending beak).
/// Canvas is 128x96; the body is centred at x=48 so the beak has room to reach right.
struct DuckSpriteView: View {
    static let canvas = CGSize(width: 128, height: 96)
    @ObservedObject var model: DuckModel

    private let outline = Color(red: 0.149, green: 0.071, blue: 0.016)

    var body: some View {
        ZStack(alignment: .topLeading) {
            foot(x: 34, lifted: model.footPhase == 0)
            foot(x: 54, lifted: model.footPhase == 1)

            // Torso/head sphere.
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFAE2B), Color(hex: 0xF69C19), Color(hex: 0xC96707)],
                                     center: UnitPoint(x: 0.4, y: 0.3), startRadius: 2, endRadius: 46))
                .overlay(Circle().stroke(outline, lineWidth: 2.5))
                .frame(width: 70, height: 70)
                .offset(x: 13, y: 8)

            // Specular crescent + dot.
            Circle().trim(from: 0.55, to: 0.72)
                .stroke(Color(hex: 0xFFF6DC), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 52, height: 52)
                .rotationEffect(.degrees(10))
                .offset(x: 22, y: 17)
            Circle().fill(Color(hex: 0xFFF6DC)).frame(width: 4, height: 4).offset(x: 24, y: 27)

            // Eye.
            Capsule().fill(Color(hex: 0x221003)).frame(width: 6, height: 11).offset(x: 62, y: 26)

            beak
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
        .rotationEffect(.degrees(model.leanDegrees), anchor: UnitPoint(x: 0.4, y: 0.9))
        .offset(y: model.bob)
        .scaleEffect(x: model.facingLeft ? -1 : 1, y: 1)
        .scaleEffect(model.scale)
        .opacity(model.opacity)
    }

    private var beak: some View {
        let length = 26 + 16 * model.beak
        return ZStack {
            Capsule().fill(Color(hex: 0xF89F1F))
            Capsule().fill(Color(hex: 0xC76607)).mask(
                VStack(spacing: 0) { Color.clear; Color.black }
            ).opacity(0.85)
            Capsule().fill(Color(hex: 0xFFC966)).frame(height: 3).padding(.horizontal, 5).offset(y: -4)
            Capsule().stroke(outline, lineWidth: 2)
        }
        .frame(width: length, height: 15)
        .offset(x: 76, y: 38)
    }

    private func foot(x: CGFloat, lifted: Bool) -> some View {
        Capsule()
            .fill(Color(hex: 0xF39617))
            .overlay(Capsule().stroke(outline, lineWidth: 2))
            .frame(width: 22, height: 9)
            .offset(x: x, y: lifted ? 78 : 85)
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Small static duck for the notch header button.
struct DuckIcon: View {
    @StateObject private var model = DuckModel()
    var body: some View {
        DuckSpriteView(model: model)
            .frame(width: DuckSpriteView.canvas.width, height: DuckSpriteView.canvas.height)
            .scaleEffect(0.17)
            .frame(width: 22, height: 17)
            .clipped()
    }
}
