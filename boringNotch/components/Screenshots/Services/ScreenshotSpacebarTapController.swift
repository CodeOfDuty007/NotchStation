//
//  ScreenshotSpacebarTapController.swift
//  boringNotch
//

import AppKit
import Foundation

/// Lets pressing Space toggle a Quick Look preview of the selected screenshot, the same way
/// Finder does - which the notch window can't get from a normal SwiftUI `.onKeyPress`/local
/// key monitor, because `BoringNotchWindow.canBecomeKey` is `false` (it never becomes the
/// key window, so keyDown events for Space go to whatever app *is* key instead of to us).
///
/// `MediaKeyInterceptor` already solves the same problem for volume/brightness keys with a
/// `CGEventTap`, which only requires the Accessibility permission this app already asks for
/// during onboarding - not a sandbox entitlement. This mirrors that approach, scoped tightly:
/// the tap is only installed while the Screenshots tab is actually on screen (reference-
/// counted, since each display has its own notch/view), and it only swallows a bare spacebar
/// keydown - every other key, and Space with any modifier held, passes through untouched.
///
/// Not `@MainActor`: the tap's C callback can't be actor-isolated. Its run loop source is
/// only ever added to `CFRunLoopGetMain()` though, so it always fires on the main thread in
/// practice, and `handle(type:cgEvent:)` uses `MainActor.assumeIsolated` to call back into
/// SwiftUI state synchronously - it needs the real answer immediately, to decide whether to
/// swallow the keystroke or let it fall through to whatever app is actually key.
final class ScreenshotSpacebarTapController {
    static let shared = ScreenshotSpacebarTapController()

    private static let spaceKeyCode: Int64 = 49

    /// Called for a bare spacebar keydown, on the main actor. Return `true` if it was handled
    /// (so the event gets swallowed); `false` lets it pass through as normal.
    var onSpacebarPressed: (@MainActor () -> Bool)?

    /// Whether the tap is actually installed and receiving events. `false` almost always means
    /// Accessibility hasn't been granted to *this exact build* - macOS ties that grant to the
    /// binary's code signature, so every ad-hoc-signed rebuild during development needs it
    /// re-granted. Read right after `activate()` returns (tap creation is synchronous) to show
    /// an "Enable Accessibility" prompt in the UI instead of failing silently.
    private(set) var isTapInstalled = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationCount = 0

    private init() {}

    /// Reference-counted: call once per view that wants the tap active, and balance it with
    /// `deactivate()` in that view's `onDisappear`. Safe to call from more than one screen.
    func activate() {
        activationCount += 1
        NSLog("🔵 ScreenshotSpacebarTapController: activate() called, activationCount=\(activationCount), alreadyInstalled=\(eventTap != nil)")
        installTap()
    }

    func deactivate() {
        activationCount = max(0, activationCount - 1)
        NSLog("🔵 ScreenshotSpacebarTapController: deactivate() called, activationCount=\(activationCount)")
        guard activationCount == 0 else { return }
        removeTap()
    }

    /// Tries again after the user has just granted Accessibility, without touching the
    /// reference count `activate()`/`deactivate()` maintain.
    func retryInstall() {
        guard eventTap == nil, activationCount > 0 else { return }
        installTap()
    }

    private func installTap() {
        guard eventTap == nil, activationCount > 0 else { return }

        // No async permission pre-check: CGEvent.tapCreate itself is the authoritative answer
        // (nil means Accessibility is missing), and it's synchronous - awaiting an XPC round
        // trip first only adds a window where deciding "is it installed yet?" is ambiguous.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                let controller = Unmanaged<ScreenshotSpacebarTapController>.fromOpaque(userInfo).takeUnretainedValue()
                return controller.handle(type: type, cgEvent: cgEvent)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else {
            isTapInstalled = false
            NSLog("⚠️ ScreenshotSpacebarTapController: CGEvent.tapCreate returned nil - Accessibility isn't granted for this build, Space preview will not work")
            return
        }
        eventTap = tap
        isTapInstalled = true
        NSLog("✅ ScreenshotSpacebarTapController: event tap installed")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isTapInstalled = false
    }

    private func handle(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap under load, or if the user is in the middle of a
        // secure-input sequence; re-enable it rather than silently going deaf on Space.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("⚠️ ScreenshotSpacebarTapController: tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard type == .keyDown, cgEvent.getIntegerValueField(.keyboardEventKeycode) == Self.spaceKeyCode else {
            return Unmanaged.passUnretained(cgEvent)
        }

        NSLog("🔵 ScreenshotSpacebarTapController: saw a spacebar keyDown (autorepeat=\(cgEvent.getIntegerValueField(.keyboardEventAutorepeat)), flags=\(cgEvent.flags.rawValue))")

        // Ignore key-repeat (holding Space down) and any modifier combination - only a bare,
        // single spacebar press toggles the preview.
        guard cgEvent.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              cgEvent.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
        else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // `onSpacebarPressed` itself decides whether this Space actually meant anything (e.g.
        // nothing selected, or the cursor isn't over the open notch); only swallow it once that
        // comes back true.
        let handled = MainActor.assumeIsolated { onSpacebarPressed?() ?? false }
        NSLog("🔵 ScreenshotSpacebarTapController: onSpacebarPressed returned \(handled)")
        return handled ? nil : Unmanaged.passUnretained(cgEvent)
    }
}
