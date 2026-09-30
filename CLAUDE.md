# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Boring Notch is a native macOS menu bar / notch app (SwiftUI + AppKit) that turns the MacBook notch into a
dynamic island-style hub: now-playing media controls with a visualizer, calendar/reminders integration, an
AirDrop-capable file "Shelf", clipboard history, webcam mirror, and replacements for the system HUDs
(volume/brightness/backlight).

## Build & run

This is an Xcode project — there is no CLI package manager or test runner to reach for by default.

```bash
open boringNotch.xcodeproj                 # open in Xcode; Cmd+R to build & run
xcodebuild -resolvePackageDependencies -project boringNotch.xcodeproj
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration debug build
```

- Requires Xcode 26+, macOS 15.6+ to build; the app itself targets macOS 14+ at runtime.
- No test target exists in the project. Don't invent `xcodebuild test` invocations or assume test coverage.
- CI (`.github/workflows/cicd.yml`) just runs a release build (`xcodebuild ... action: build`) on every push/PR — that's the closest thing to a "does it compile" gate.
- Release builds (`build_reusable.yml`) archive, export, and package a DMG via `Configuration/dmg/create_dmg.sh`; not something you'd normally run locally.

## Branching

All code contributions target `main` directly. See CONTRIBUTING.md.

## Architecture

### Targets

- **boringNotch** — the main app (SwiftUI + AppKit), sandboxed.
- **BoringNotchXPCHelper** — a small privileged-ish XPC helper process (`BoringNotchXPCHelper/`) that the
  sandboxed main app talks to for things it can't do directly: checking/requesting Accessibility
  authorization (`AXIsProcessTrusted`) and keyboard-backlight brightness (IOKit). The main app talks to it
  through `boringNotch/XPCHelperClient/XPCHelperClient.swift` against the
  `BoringNotchXPCHelperProtocol` (mirrored in both targets — keep them in sync when changing the protocol).

### App lifecycle & window management

There's no single root `View`. `boringNotchApp.swift`'s `AppDelegate` owns a **per-screen** dictionary of
windows/view-models (`windows: [String: NSWindow]`, `viewModels: [String: BoringViewModel]`, keyed by
screen UUID from `NSScreen+UUID.swift`), because the notch UI must be independently instantiated on every
display. Screen connect/disconnect and lock/unlock (`onScreenLocked`/`onScreenUnlocked`) all flow through
this delegate, which recreates/tears down windows accordingly. `BoringNotchWindow` /
`BoringNotchSkyLightWindow` (via the `SkyLightWindow` package) are the custom `NSWindow` subclasses that
sit above/around the physical notch.

`BoringViewCoordinator.shared` (`BoringViewCoordinator.swift`) is the cross-window singleton
`ObservableObject` that owns which tab/view is showing (`currentView: NotchViews`), sneak-peek/HUD state,
and persisted UI toggles (`@AppStorage`). `BoringViewModel` (one per screen) holds the rest of the
per-window notch state (expanded/closed, sizing, hover).

### Media playback

`MusicManager.shared` is the single source of truth for now-playing UI state (title/artist/artwork/playback
position/etc.), consumed by the visualizer and live-activity views. It doesn't talk to apps directly —
it holds one `activeController: any MediaControllerProtocol` and switches between implementations:

- `NowPlayingController` — wraps macOS's private MediaRemote framework via the bundled
  `mediaremote-adapter/` Perl script + `MediaRemoteAdapter.framework` (see that directory's own
  license/readme; it's a vendored third-party adapter, not something to "clean up").
- `AppleMusicController` / `SpotifyController` — AppleScript-driven, used for capabilities MediaRemote
  doesn't expose (e.g. favorite/like), gated by app bundle identifier.
- `YouTube Music Controller/` — a whole separate networking-based controller (auth, models, networking
  split into their own files) for controlling YouTube Music web playback.

When adding a new media source, implement `MediaControllerProtocol` and wire it into `MusicManager`'s
controller-selection logic rather than special-casing it elsewhere.

### Feature areas under `boringNotch/components/`

Each subfolder is a fairly self-contained feature; most follow a Model(s) → ViewModel → View split when
they have real state (see `Shelf/` for the fullest example: `Models/`, `Services/`, `ViewModels/`, `Views/`
as separate directories). Notable ones:

- `Shelf/` — AirDrop/drag-drop file tray. `Services/` holds single-purpose helpers (thumbnailing, quicklook,
  quick-share, temp file storage, persistence) composed by `ShelfStateViewModel`.
- `Clipboard/` — clipboard history capture + view; the monitor auto-starts at app launch (see recent
  commits) rather than only while the tab is open.
- `Calendar/` — reads from `CalendarManager`/`CalendarServiceProviding` (EventKit-backed).
- `Live activities/` — the Dynamic-Island-style HUD/inline widgets (battery, download progress, system
  event indicators like volume/brightness) shown when the notch is collapsed.
- `Settings/` — the standalone settings window (`SettingsWindowController`), separate from the notch
  windows themselves.
- `Onboarding/` — first-launch permission requests and walkthrough.

### Persistence & config

- User preferences use `Defaults` (sindresorhus/Defaults) — look for `Defaults.Keys` extensions near the
  feature they configure rather than one central file; `boringNotch/models/Constants.swift` has shared
  app-wide constants and a few cross-cutting `Defaults.Serializable` types (e.g. `CustomVisualizer`).
  Coordinator-local toggles instead use `@AppStorage` directly (see `BoringViewCoordinator`).
- Keyboard shortcuts: `KeyboardShortcuts` package + `boringNotch/Shortcuts/ShortcutConstants.swift` +
  `extensions/KeyboardShortcutsHelper.swift`.
- Auto-update: Sparkle, wired up in `boringNotchApp.swift` (`SPUStandardUpdaterController`) and
  `Settings/SoftwareUpdater.swift`; appcast/DMG generation lives under `Configuration/`.

### Sandboxing & entitlements

The app is sandboxed (`boringNotch/boringNotch.entitlements`). It has temporary-exception entitlements to
send Apple Events to Music/Spotify specifically, and mach-lookup exceptions for the Sparkle XPC services.
If you add a feature that needs a new capability (new automation target, new file access pattern, etc.),
it almost certainly needs a matching entitlement — check here first when something works in a debug build
run outside the sandbox but fails to compile/run signed.

### Localization

Strings live in `boringNotch/Localizable.xcstrings` (String Catalog) and sync to/from Crowdin automatically
per `crowdin.yml` — don't hand-edit translations for other locales, only add/change the base English
strings and let Crowdin PRs bring translations back.
