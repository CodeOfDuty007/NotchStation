# NotchStation

**NotchStation** turns your MacBook's notch into a control hub: now-playing media with a visualizer,
calendar/reminders, an AirDrop-capable file shelf, a webcam mirror, system HUD replacements — plus a
**clipboard history tab**, a **screenshots tray**, a **Pomodoro timer**, and an **anti-doomscroll duck**, added on top of the original app.

Built on and credited to **[Boring Notch](https://github.com/TheBoredTeam/boring.notch)** by
[TheBoredTeam](https://github.com/TheBoredTeam). See [License & Attribution](#license--attribution) below —
this project is a GPL-3.0 modified version of their work, not an independent creation.

---

## What's new here

Boring Notch already covers now-playing media, calendar/reminders, the AirDrop shelf, webcam mirror, and
HUD replacements. This fork adds three features on top of that:

### 📋 Clipboard History

A dedicated notch tab that auto-captures your clipboard as you copy, so you can scroll back through
recent items instead of losing them the moment you copy something else. Monitoring starts automatically
when the app launches — no toggle to remember.

### 🖼️ Screenshots Tray

A recent-screenshots wheel built into the notch:
- Cmd-click to select multiple screenshots at once
- Hover to reveal a quick delete action
- Tap Space for a quick preview
- Drag a screenshot out of the tray and it's automatically trashed — clean up as you go, without a separate
  "delete" step

### ⏱️ Pomodoro Timer

A work/rest timer built into the notch, opened from the stopwatch button on the right of the notch header
(next to the settings gear and battery, so it clears the physical notch).

- **Two timers — work and rest.** Tap the **WORK** or **REST** label to choose which one is active; the
  active one is highlighted in your accent color. Defaults are 25:00 work and 5:00 rest.
- **Set the time your way.** Tap a time to edit it: scroll the minute/second wheels (mouse wheel, trackpad,
  drag, or click a row) or just type it — `25` for minutes, or `25:30` for minutes and seconds. Wheels and
  typed text stay in sync, and invalid input is rejected with a red outline.
- **Mute / unmute button (bottom right).**
  - *Unmuted:* when time is up, a macOS alert sound loops at full app volume until you dismiss it (your
    Mac's system volume is never touched), and the notch opens once with a Dismiss button. A small
    music-note menu next to the button picks the sound.
  - *Muted:* no sound — instead the notch rapidly opens and closes, then stays open on a black screen
    with accent-colored waves until you dismiss it.
- **Countdown bar.** While a timer is running or paused, a small bar slides out of the left side of the
  closed notch showing the time left (work or rest, whichever is active) with a thin progress line, so you
  can check without opening the notch. Click it to jump to the Pomodoro tab.
- **Keeps running in the background.** The timer counts down from a fixed end time, so it stays accurate
  while the notch is closed, on another tab, or across sleep, and the alarm fires wherever you are.
- Controls on the ring: play/pause, reset, and skip to the other phase. Durations, mute state, and the
  chosen sound are remembered between launches.

### 🦆 Anti-Doomscroll Duck

An always-running guard, opened from the duck button in the notch header (next to the Pomodoro button). You
list websites and apps with a time allowance; when you overspend, a small duck walks out and closes them.

- **Rules.** Add a *website* as a base URL (`instagram.com` - also matches `www.` and subdomains, never
  look-alikes such as `notinstagram.com`) or a URL with a path (`reddit.com/r/all` matches that path and
  below), or any *installed app*, plus a limit in minutes. Firefox exposes no tab scripting, so it can only be
  limited as a whole app.
- **Counts only what you are actually looking at.** Time accrues only while the rule is the active tab of the
  front window of the frontmost browser (or the frontmost app, for app rules). Closing the tab does **not**
  reset the clock. Each allowance renews 12 hours after its first use in a window.
- **The duck.** When a limit is spent the duck floats down from the top edge of the screen the browser is on,
  walks along the tab strip to the active tab's close button, extends its beak, pecks, and the tab closes. It
  closes **every** matching tab - foreground and background, every window, every supported browser - in one
  outing, and it docks only when none are left. If you open more matching tabs while it is walking home it
  U-turns immediately instead of docking first. Works on external displays; it always returns to the Mac's
  built-in (notch) screen, walks slowly to the notch and fades away.
- **Only one off switch.** The master slider in the tab. Off = nothing is read, nothing is closed, the duck
  is sent home. There is no per-rule pause or reset.
- **Evidence and logs.** For each tab it takes a screenshot of just that browser window before and after the
  close (needs Screen Recording; skipped if denied) and appends a line to `DoomLog/log.txt` in the app's
  Application Support folder with the outcome and the reason for any failure.
- **Safety.** Never launches a closed browser, re-verifies the address right before closing, never
  force-quits an app (it asks politely, then hides it), and a failed close backs off for 3 minutes instead of
  retrying. Supported browsers: Safari, Chrome (+Canary), Chromium, Brave, Edge, Arc, Vivaldi, Opera - each
  asks for macOS Automation permission once.
- **Known limits.** The beak's aim at the close button is estimated from the window frame, tab count and
  active tab index (scripting exposes no tab geometry; calibrated on Chrome) - the close itself is done by
  scripting. If an app refuses to quit, it is hidden instead.

## Everything from upstream

- 🎧 Now-playing media controls with a visualizer
- 📆 Calendar and reminders integration
- 📚 AirDrop-capable file shelf
- 📷 Webcam mirror
- 🎚️ System HUD replacements (volume, brightness, keyboard backlight)
- 👆 Customizable gesture controls

## Installation

**System Requirements:** macOS 14 Sonoma or later, Apple Silicon or Intel Mac.

This fork is currently source-only — there's no signed release build yet, so you'll need to build it
yourself (see below). If you just want the original app without the clipboard/screenshots additions,
grab a release from [upstream Boring Notch](https://github.com/TheBoredTeam/boring.notch/releases/latest)
or via `brew install --cask TheBoredTeam/boring-notch/boring-notch`.

## Building from Source

### Prerequisites

- macOS 15.6 or later
- Xcode 26 or later

### Steps

1. **Clone this repository**:
   ```bash
   git clone https://github.com/CodeOfDuty007/NotchStation.git
   cd NotchStation
   ```

2. **Open the project in Xcode**:
   ```bash
   open boringNotch.xcodeproj
   ```

3. **Build and run**: press `Cmd + R`.

There's no CLI package manager or test runner for this project — Xcode is the build system. See
[CLAUDE.md](./CLAUDE.md) for a deeper architecture walkthrough if you're digging into the code.

## Usage

- Launch the app — your notch now hosts the full tab set, including Clipboard and Screenshots, plus the Pomodoro button in the header.
- Hover over the notch to expand it and switch between tabs.
- Click the stopwatch button in the notch header to start a Pomodoro; start it and close the notch to see
  the countdown bar beside the notch.
- Click the duck button in the notch header, add a site or app with a limit and flip the slider on; macOS will
  ask once for Automation (and Screen Recording, for the before/after screenshots) permission.
- Click the menu bar icon to customize behavior.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). This is a personal fork, so the workflow is lighter-weight than
upstream's, but pull requests are welcome.

## License & Attribution

This project is a **modified version of [Boring Notch](https://github.com/TheBoredTeam/boring.notch)**,
copyright © TheBoredTeam, licensed under the **GNU General Public License v3.0** (see [LICENSE](./LICENSE)).
As required by GPL-3.0 §5(a), this notice records that modifications were made:

> Modified by [@CodeOfDuty007](https://github.com/CodeOfDuty007), 2026: added a Clipboard History tab (auto-capture, launch-time monitoring)
> a Screenshots tray (multi-select, hover-delete, Space preview, drag-to-trash), and a Pomodoro timer tab
> (work/rest timers, scroll-wheel and typed time entry, mute/visual alarm, closed-notch countdown bar), and an
> Anti-Doomscroll tab (per-site/app time limits counted on the active tab only, with a desktop duck that closes
> tabs through browser scripting); disabled Sparkle's
> automatic update checks and removed the upstream appcast feed URL, since this fork doesn't publish its
> own releases; reworked repository docs and CI to fit a personal fork rather than the upstream project.

This project remains licensed under GPL-3.0, same as upstream. All rights and obligations of that license
apply to this repository and any further redistribution of it.

### Upstream acknowledgments

Carried over from the original project — full credit belongs to these authors and projects, not to this
fork:

- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** — enables the Now Playing source
  on macOS 15.4+.
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** — instrumental in the original "Shelf" feature.
- Icon credits: [@maxtron95](https://github.com/maxtron95)
- Website credits: [@himanshhhhuv](https://github.com/himanshhhhuv)

For the full list of third-party licenses, see [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES).

If you'd like to support the original Boring Notch team directly, see their
[Ko-fi](https://www.ko-fi.com/alexander5015) and [Discord](https://discord.gg/GvYcYpAKTu).
