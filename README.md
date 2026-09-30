# NotchStation

**NotchStation** turns your MacBook's notch into a control hub: now-playing media with a visualizer,
calendar/reminders, an AirDrop-capable file shelf, a webcam mirror, system HUD replacements — plus a
**clipboard history tab** and a **screenshots tray**, added on top of the original app.

Built on and credited to **[Boring Notch](https://github.com/TheBoredTeam/boring.notch)** by
[TheBoredTeam](https://github.com/TheBoredTeam). See [License & Attribution](#license--attribution) below —
this project is a GPL-3.0 modified version of their work, not an independent creation.

---

## What's new here

Boring Notch already covers now-playing media, calendar/reminders, the AirDrop shelf, webcam mirror, and
HUD replacements. This fork adds two features on top of that:

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

- Launch the app — your notch now hosts the full tab set, including Clipboard and Screenshots.
- Hover over the notch to expand it and switch between tabs.
- Click the menu bar icon to customize behavior.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). This is a personal fork, so the workflow is lighter-weight than
upstream's, but pull requests are welcome.

## License & Attribution

This project is a **modified version of [Boring Notch](https://github.com/TheBoredTeam/boring.notch)**,
copyright © TheBoredTeam, licensed under the **GNU General Public License v3.0** (see [LICENSE](./LICENSE)).
As required by GPL-3.0 §5(a), this notice records that modifications were made:

> Modified by Nikhil Khurana, 2026: added a Clipboard History tab (auto-capture, launch-time monitoring)
> and a Screenshots tray (multi-select, hover-delete, Space preview, drag-to-trash), plus supporting
> project documentation. All other functionality is unchanged from upstream.

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
