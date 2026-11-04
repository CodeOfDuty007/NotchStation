//
//  PomodoroTimeWheel.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// A scroll wheel for picking a number (macOS has no `.wheel` picker style). Scrolling with a
/// mouse wheel or trackpad steps the value, as does dragging; clicking a visible row jumps to
/// it. The selected row sits in an accent-coloured band.
///
/// This deliberately doesn't use a SwiftUI `ScrollView`: the notch owns vertical scrolling (a
/// swipe up closes it) and snapping scroll positions proved unreliable inside it, so scroll
/// events over the wheel are captured here directly.
struct PomodoroTimeWheel: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String

    @EnvironmentObject private var vm: BoringViewModel
    @State private var scrollRemainder: CGFloat = 0
    @State private var dragRemainder: CGFloat = 0

    private let rowHeight: CGFloat = 26
    private let visibleHeight: CGFloat = 78
    /// Trackpad points of scrolling per step, and mouse-wheel notches per step.
    private let pointsPerStep: CGFloat = 14

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.effectiveAccent.opacity(0.22))
                    .frame(height: rowHeight)

                ForEach(visibleValues, id: \.self) { n in
                    Text(String(format: "%02d", n))
                        .font(.system(size: n == value ? 20 : 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(n == value ? Color.effectiveAccent : Color.gray.opacity(0.7))
                        .frame(width: 56, height: rowHeight)
                        .contentShape(Rectangle())
                        .offset(y: CGFloat(n - value) * rowHeight)
                        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { value = n } }
                }
            }
            .frame(width: 56, height: visibleHeight)
            .clipped()
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.25),
                    .init(color: .black, location: 0.75),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .background(PomodoroScrollCapture { delta, precise in handleScroll(delta, precise: precise) })
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        // Dragging up moves to larger values, like pulling the wheel up.
                        let total = -drag.translation.height - dragRemainder
                        let steps = Int(total / 12)
                        if steps != 0 {
                            step(steps)
                            dragRemainder += CGFloat(steps) * 12
                        }
                    }
                    .onEnded { _ in dragRemainder = 0 }
            )
            // The notch closes on an upward scroll; the same flag the calendar uses to opt out.
            .onHover { vm.isHoveringCalendar = $0 }
            .onDisappear { vm.isHoveringCalendar = false }

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.gray)
        }
    }

    private var visibleValues: [Int] {
        ((value - 2)...(value + 2)).filter { range.contains($0) }
    }

    private func step(_ delta: Int) {
        let next = min(max(value + delta, range.lowerBound), range.upperBound)
        guard next != value else { return }
        withAnimation(.snappy(duration: 0.15)) { value = next }
    }

    private func handleScroll(_ delta: CGFloat, precise: Bool) {
        // Content follows the fingers, so scrolling "up" (negative delta) reveals larger values.
        scrollRemainder += -delta / (precise ? pointsPerStep : 1)
        let steps = Int(scrollRemainder)
        if steps != 0 {
            scrollRemainder -= CGFloat(steps)
            step(steps)
        }
    }
}

/// Reports vertical scroll-wheel movement that happens over its bounds. Uses a local event
/// monitor (as the notch's own pan gesture does) because the notch window never becomes key
/// and sits in a hosting view that would otherwise route the event elsewhere.
struct PomodoroScrollCapture: NSViewRepresentable {
    let onScroll: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.onScroll = onScroll
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var onScroll: ((CGFloat, Bool) -> Void)?
        private var monitor: Any?

        func install(on view: NSView) {
            remove()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let self, let view, let window = view.window, event.window === window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                self.onScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                return nil // consumed: don't let the notch treat it as a swipe
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}
