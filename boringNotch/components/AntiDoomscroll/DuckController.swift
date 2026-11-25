//
//  DuckController.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// Where and how the duck should perform one close-the-target trip. Coordinates are Cocoa
/// (origin bottom-left of the primary display), already converted from Quartz coordinates.
struct DuckTrip {
    /// The on-screen point the beak should reach (the tab's X, or an app's red close dot).
    var target: CGPoint
    var facingLeft: Bool
    var screenFrame: CGRect
    /// Runs at the moment of the peck. Returns whether something was really closed.
    var action: @MainActor () async -> Bool
}

enum DuckGeometry {
    /// Quartz (top-left origin, primary display) rect -> Cocoa (bottom-left origin) rect.
    static func cocoaRect(fromQuartz r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The screen containing the rect's centre (falls back to the best overlap, then the main screen).
    static func screen(for cocoaRect: CGRect, screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let c = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        if let hit = screens.first(where: { $0.frame.contains(c) }) { return hit }
        return screens.max { $0.frame.intersection(cocoaRect).area < $1.frame.intersection(cocoaRect).area } ?? NSScreen.main
    }

    /// Estimated position of the active tab's close "X". Scripting exposes no tab geometry, so
    /// this is derived from the window frame, the tab count and the active tab's index
    /// (Chromium browsers: tabs share the strip between the traffic lights and the new-tab
    /// button, close button at the tab's right; Safari: tabs share the full width, close
    /// button at the tab's left). The close itself is done by scripting, not by this point.
    static func tabTarget(windowCocoa r: CGRect, isSafari: Bool, index: Int, count: Int) -> CGPoint {
        let n = CGFloat(max(count, 1)), i = CGFloat(min(max(index, 1), max(count, 1)))
        if isSafari {
            let w = r.width / n
            return CGPoint(x: min(r.minX + (i - 1) * w + 16, r.maxX - 40), y: r.maxY - 66)
        }
        // Calibrated on Chrome: tabs start ~100pt in (traffic lights + tab-search button), are
        // up to 240pt wide with a 2pt overlap, and the cross sits 19pt from a tab's right edge.
        let left: CGFloat = 100, right: CGFloat = 90, overlap: CGFloat = 2
        let tabW = min(240, max(60, (r.width - left - right) / n + overlap))
        let x = r.minX + left + (i - 1) * (tabW - overlap) + tabW - 19
        return CGPoint(x: min(x, r.maxX - 90), y: r.maxY - 20)
    }

    /// The red close dot of a standard macOS window.
    static func appTarget(windowCocoa r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + 20, y: r.maxY - 14)
    }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

/// Owns the single click-through duck window and drives the choreography:
/// float down from the notch/top edge -> walk to the target -> extend beak -> lunge (close)
/// -> walk slowly back along the screen -> climb up and park at home on the notch.
/// Once docked at home it fades out and stays hidden until the next trip.
@MainActor
final class DuckController {
    static let shared = DuckController()

    /// The duck is drawn on a 128x96 canvas; it is shown at this fraction of that size.
    static let scale: CGFloat = 0.42

    private let model = DuckModel()
    private var panel: NSPanel?
    private var aborted = false
    private var parkedScreen: CGRect?
    private(set) var isRunning = false
    /// Set while walking home when a new target appears: every animation step then ends at once.
    private var uturn = false

    private let s = DuckController.scale
    private var spriteSize: CGSize { CGSize(width: DuckSpriteView.canvas.width * s, height: DuckSpriteView.canvas.height * s) }
    private var beakTipExtended: CGFloat { 118 * s }   // beak tip when fully extended, facing right
    private var feetToBeak: CGFloat { 44 * s }         // baseline -> beak height

    private init() {}

    func abort() {
        aborted = true
        parkedScreen = nil
        panel?.orderOut(nil)   // the duck vanishes the moment the switch goes off
    }

    /// One outing: visit `first`, then keep asking `next` for further targets (more tabs to
    /// close) and visit each in turn; only when none are left does the duck head home and dock.
    func run(_ first: DuckTrip, next: @escaping @MainActor () async -> DuckTrip? = { nil }) async {
        guard !isRunning else { return }
        isRunning = true
        aborted = false
        defer { isRunning = false }

        let panel = ensurePanel()
        model.beak = 0; model.leanDegrees = 0; model.bob = 0; model.opacity = 1; model.scale = 1; model.footPhase = 0

        var stop = first
        var last: (x: CGFloat, y: CGFloat, screen: CGRect)?
        outer: while true {
        uturn = false
        model.opacity = 1; model.scale = 1
        while true {
            let screen = stop.screenFrame
            let dir: CGFloat = stop.facingLeft ? -1 : 1
            let gap: CGFloat = 1
            let tipLocal = stop.facingLeft ? spriteSize.width - beakTipExtended : beakTipExtended
            var standX = stop.target.x - dir * gap - tipLocal
            standX = min(max(standX, screen.minX - 10), screen.maxX - spriteSize.width + 10)
            let originY = min(max(stop.target.y - 50.5 * s, screen.minY + 5), screen.maxY - spriteSize.height - 5)

            if let l = last, l.screen == screen {
                // Next tab on the same display: walk over to it.
                let dist = hypot(standX - l.x, originY - l.y)
                model.facingLeft = standX < l.x
                await tween(max(0.5, Double(dist) / 110)) { t in
                    let e = t * t * (3 - 2 * t)
                    self.place(panel, x: l.x + (standX - l.x) * e, y: l.y + (originY - l.y) * e)
                    self.model.footPhase = Int(Double(dist) * e / 6) % 2
                }
                model.footPhase = 0
                model.facingLeft = stop.facingLeft
            } else {
                // First stop (or a tab on another display): drop in from the top edge, then walk up to it.
                model.facingLeft = stop.facingLeft
                let approach = standX - dir * 90
                place(panel, x: approach, y: screen.maxY + 4)
                panel.orderFrontRegardless()
                await tween(1.2) { t in
                    let e = 1 - pow(1 - t, 3)
                    self.place(panel, x: approach, y: screen.maxY + 4 + (originY - screen.maxY - 4) * e)
                    self.model.bob = CGFloat(sin(t * .pi * 4)) * 2 * (1 - t)
                }
                model.bob = 0
                let walk = abs(standX - approach)
                await tween(max(0.3, Double(walk) / 80)) { t in
                    let e = 1 - pow(1 - t, 2)
                    self.place(panel, x: approach + (standX - approach) * e, y: originY)
                    self.model.footPhase = Int(Double(walk) * e / 6) % 2
                }
                model.footPhase = 0
            }
            last = (standX, originY, screen)
            guard !aborted else { return }

            // Lean in and extend the beak, then peck: a quick lunge while the close is dispatched.
            await tween(0.3) { t in
                self.model.beak = CGFloat(t)
                self.model.leanDegrees = Double(dir) * 6 * t
            }
            if !aborted {
                let closing = Task { @MainActor in await stop.action() }
                await tween(0.1) { t in self.place(panel, x: standX + dir * 7 * CGFloat(t), y: originY) }
                _ = await closing.value
                await tween(0.18) { t in
                    self.place(panel, x: standX + dir * 7 * CGFloat(1 - t), y: originY)
                    self.model.beak = CGFloat(1 - t)
                    self.model.leanDegrees = Double(dir) * 6 * (1 - t)
                }
            }
            guard !aborted else { return }
            model.beak = 0; model.leanDegrees = 0
            guard let following = await next() else { break }
            stop = following
        }
        guard !aborted, let end = last else { return }

        // Back home - only once nothing is left to close. While walking, keep asking for newly
        // opened matching tabs: if any appear, U-turn on the spot instead of docking first.
        var pending: DuckTrip?
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled || self.aborted { break }
                if let n = await next() { pending = n; self.uturn = true; break }
            }
        }
        let docked = await goHome(panel, from: end)
        poller.cancel()
        await poller.value
        guard !aborted else { return }
        if let again = pending {
            stop = again
            if docked {
                last = nil   // hidden at the notch: drop in from the top edge again
            } else {
                let frame = panel.frame
                let screenFrame = DuckGeometry.screen(for: frame)?.frame ?? end.screen
                last = (frame.origin.x, frame.origin.y, screenFrame)
            }
            continue outer
        }
        return
        }
    }

    // MARK: Pieces

    /// The Mac's own (notched / built-in) display: the duck's home, whatever screen it worked on.
    static func homeScreenFrame() -> CGRect? {
        let screens = NSScreen.screens
        let builtIn = screens.first { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        return (builtIn ?? screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first)?.frame
    }

    /// Home: centred on the notch, tucked against the top edge of the screen.
    private func homeOrigin(on screen: CGRect) -> CGPoint {
        CGPoint(x: screen.midX - spriteSize.width / 2, y: screen.maxY - spriteSize.height)
    }

    /// Walks the duck home and docks it. Returns false if it was interrupted (U-turn or abort).
    private func goHome(_ panel: NSPanel, from end: (x: CGFloat, y: CGFloat, screen: CGRect)) async -> Bool {
        // On the built-in screen: walk to the notch. On an external screen: walk slowly off the
        // edge toward the built-in display, come in from the matching edge there, carry on.
        let homeFrame = Self.homeScreenFrame() ?? end.screen
        if homeFrame == end.screen {
            return await walkHome(panel, screen: end.screen, from: end.x, y: end.y)
        }
        let exitDir: CGFloat = homeFrame.midX < end.screen.midX ? -1 : 1
        let exitX = exitDir < 0 ? end.screen.minX - spriteSize.width : end.screen.maxX
        model.facingLeft = exitDir < 0
        let dist = abs(exitX - end.x)
        await tween(max(0.5, Double(dist) / 55)) { t in
            self.place(panel, x: end.x + (exitX - end.x) * t, y: end.y)
            self.model.footPhase = Int(Double(dist) * t / 5) % 2
        }
        guard !aborted, !uturn else { return false }
        let entryX = exitDir < 0 ? homeFrame.maxX : homeFrame.minX - spriteSize.width
        let entryY = homeFrame.maxY - spriteSize.height - 70
        place(panel, x: entryX, y: entryY)
        return await walkHome(panel, screen: homeFrame, from: entryX, y: entryY)
    }

    /// Slow walk back along the screen, a gentle climb up to the notch, then fade away.
    private func walkHome(_ panel: NSPanel, screen: CGRect, from x: CGFloat, y: CGFloat) async -> Bool {
        model.beak = 0; model.leanDegrees = 0
        let home = homeOrigin(on: screen)
        model.facingLeft = home.x < x
        let dist = abs(home.x - x)
        await tween(max(0.5, Double(dist) / 55)) { t in
            self.place(panel, x: x + (home.x - x) * t, y: y)
            self.model.footPhase = Int(Double(dist) * t / 5) % 2
            self.model.bob = -abs(CGFloat(sin(t * .pi * max(2, Double(dist) / 30)))) * 2
        }
        model.bob = 0; model.footPhase = 0
        guard !aborted, !uturn else { return false }
        await tween(1.0) { t in
            let e = t * t * (3 - 2 * t)
            self.place(panel, x: home.x, y: y + (home.y - y) * e)
        }
        guard !aborted, !uturn else { return false }
        // Docked: tuck the duck away completely (a parked duck's feet would dangle below the notch).
        await tween(0.35) { t in
            self.model.opacity = 1 - t
            self.model.scale = 1 - 0.5 * CGFloat(t)
        }
        guard !aborted, !uturn else { return false }
        panel.orderOut(nil)
        model.opacity = 1; model.scale = 1; model.facingLeft = false
        parkedScreen = nil
        return true
    }

    private func place(_ panel: NSPanel, x: CGFloat, y: CGFloat) {
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Runs `step(t)` for t in 0...1 over `duration` seconds at ~60 fps; ends early if aborted or U-turning.
    private func tween(_ duration: Double, _ step: @MainActor (Double) -> Void) async {
        let start = CACurrentMediaTime()
        while !aborted && !uturn {
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            step(t)
            if t >= 1 { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = DuckPanel(contentRect: NSRect(origin: .zero, size: spriteSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true          // click-through: never blocks the user's browser
        p.level = .screenSaver
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = DuckSpriteView(model: model)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: spriteSize.width, height: spriteSize.height, alignment: .topLeading)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: spriteSize)
        p.contentView = host
        panel = p
        return p
    }
}

/// Borderless panels may be placed partly/fully off-screen (the duck starts above the top edge).
private final class DuckPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
