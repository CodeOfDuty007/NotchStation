//
//  PomodoroTimeEditor.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// Edit one timer's length: scroll the minute/second wheels, or type a time ("25", "25:30").
/// The notch window normally can't become key (so it never steals focus), which would make the
/// text field unusable; while this editor is up it's allowed to, and the notch is held open.
struct PomodoroTimeEditor: View {
    let title: String
    let initialSeconds: Int
    let onDone: (Int) -> Void
    let onCancel: () -> Void

    @State private var minutes: Int
    @State private var seconds: Int
    @State private var text: String
    @State private var hostWindow: NSWindow?
    @State private var holdingNotchOpen = false
    /// The app that had keyboard focus before the editor took it, so we can give it back.
    @State private var previousApp: NSRunningApplication?
    @FocusState private var fieldFocused: Bool

    init(title: String, initialSeconds: Int, onDone: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.initialSeconds = initialSeconds
        self.onDone = onDone
        self.onCancel = onCancel
        _minutes = State(initialValue: initialSeconds / 60)
        _seconds = State(initialValue: initialSeconds % 60)
        _text = State(initialValue: PomodoroTimeFormat.display(TimeInterval(initialSeconds)))
    }

    private var totalSeconds: Int { PomodoroTimeFormat.clamp(minutes * 60 + seconds) }

    var body: some View {
        HStack(spacing: 14) {
            PomodoroTimeWheel(value: $minutes, range: 0...PomodoroTimeFormat.maxMinutes, label: "min")
            Text(":")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.effectiveAccent)
                .padding(.bottom, 12)
            PomodoroTimeWheel(value: $seconds, range: 0...59, label: "sec")

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                TextField("mm:ss", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 90)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(textIsValid ? Color.effectiveAccent : Color.red, lineWidth: 1.5))
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onChange(of: text) { _, new in applyTyped(new) }
                HStack(spacing: 6) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                    Button(action: commit) {
                        Text("Set")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.effectiveAccent))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.effectiveAccent.opacity(0.6), lineWidth: 1))
        .background(PomodoroWindowReader { hostWindow = $0 })
        .onChange(of: minutes) { _, _ in syncTextFromWheels() }
        .onChange(of: seconds) { _, _ in syncTextFromWheels() }
        .onAppear(perform: beginTextEntry)
        .onDisappear(perform: endTextEntry)
        // `onDisappear` isn't guaranteed when the whole window is closed (screen lock, display
        // change); release the notch hold and key-window flag from here too. Idempotent.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let closing = note.object as? NSWindow, closing === hostWindow { endTextEntry() }
        }
        .onExitCommand(perform: onCancel)
    }

    private var textIsValid: Bool { PomodoroTimeFormat.parse(text) != nil }

    /// Invalid typed text is rejected (red outline) rather than silently saving the wheel value.
    private func commit() {
        guard let typed = PomodoroTimeFormat.parse(text) else { return }
        onDone(typed)
    }

    /// Typed text drives the wheels (only when it parses; half-typed input is left alone).
    private func applyTyped(_ new: String) {
        guard let value = PomodoroTimeFormat.parse(new) else { return }
        if value / 60 != minutes { minutes = value / 60 }
        if value % 60 != seconds { seconds = value % 60 }
    }

    private func syncTextFromWheels() {
        let shown = PomodoroTimeFormat.display(TimeInterval(totalSeconds))
        // Don't fight the user while they're typing something that already means this time.
        if PomodoroTimeFormat.parse(text) != totalSeconds { text = shown }
    }

    private func beginTextEntry() {
        guard !holdingNotchOpen else { return }
        holdingNotchOpen = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front
        SharingStateManager.shared.beginInteraction()
        BoringNotchSkyLightWindow.textEntryHolders += 1
        DispatchQueue.main.async {
            hostWindow?.makeKey()
            fieldFocused = true
        }
    }

    private func endTextEntry() {
        guard holdingNotchOpen else { return }
        holdingNotchOpen = false
        BoringNotchSkyLightWindow.textEntryHolders = max(0, BoringNotchSkyLightWindow.textEntryHolders - 1)
        // `resignKey()` is only a callback; focus actually moves by activating another app.
        if let window = hostWindow, window.isKeyWindow { previousApp?.activate() }
        previousApp = nil
        SharingStateManager.shared.endInteraction()
    }
}

/// Hands back the `NSWindow` hosting a SwiftUI view.
struct PomodoroWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
