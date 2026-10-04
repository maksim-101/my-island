# my-island

A native macOS notch app — an **actionable-first** companion for the camera-housing notch.
The collapsed notch always shows live ambient state; it expands on hover or a global hotkey
(⌥Space by default) into a band of modules for now playing, timers, the next meeting and the
clipboard, each opening a detail droplet with its actions.

Actionable, not decorative — the notch surfaces what needs your attention and lets you act
on it (or jump straight to it) without switching windows.

> Built as a personal daily-driver on a 16" MacBook Pro, but nothing is hardware-specific:
> the notch layout is derived from Apple's public safe-area APIs, so it should work on any
> notched Mac (14"/16" MacBook Pro, notched MacBook Air) — those are just untested. Displays
> **without** a notch (external monitors, notchless Macs) get a synthetic pill under the menu
> bar that behaves the same way; Settings -> Displays turns it off.

![The open my-island band on a notchless display: Now Playing, a running focus timer, the next meeting and the latest clipboard entry](docs/screenshot.png)

## Status

**In active development.** Prebuilt, notarized builds are on the
[Releases](https://github.com/maksim-101/my-island/releases) page; `main` may be ahead of the
latest release.

| Area | State |
|------|-------|
| Notch shell: always-on collapsed state, hover-to-expand, global hotkey | ✅ Working |
| Notchless displays: synthetic pill on every connected display, shallow bulge over fullscreen apps | ✅ Working |
| Band + detail droplets, switchable modules (Settings -> Modules) | ✅ Working |
| Timers / focus (pomodoro + countdown), shown as a line along the notch outline | ✅ Working |
| Clipboard history (10 entries, password-manager copies skipped) | ✅ Working |
| Calendar next-meeting alert + one-click join | ✅ Working |
| Now Playing (Apple Music + browser audio) + live CoreAudio sound-wave | ✅ Working |
| Brightness + volume HUD, drawn as a drop out of the notch | ✅ Working |
| Replace the system brightness bezel (optional, needs Accessibility) | ✅ Working |
| Volume HUD that yields to FineTune | ✅ Working |
| Own visual design language ([`DESIGN.md`](DESIGN.md)) | ✅ Working |
| Camera mirror + microphone level / mute | Planned |
| Quick actions (keep-awake, Reminders due today, Shortcuts), self-update, Homebrew cask | Planned |
| Downloads / transfers progress | Backlogged |

### Opening the band

Rest the pointer in the upper two-thirds of the notch (or pill) for about a third of a second,
or press the hotkey. The lower third and the strip just below the notch never open it, so a
pointer passing by on its way to a tab bar right under the notch leaves it alone. Moving away
from the band closes it again.

## Requirements

- **macOS 26 (Tahoe)** or later (developed on a 16" MacBook Pro, currently on macOS 27). Any
  Mac works; on a notchless display the app draws its own pill.
- To build from source: **Xcode 26** or later with command-line tools
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Install a release

Download the zip from the latest [release](https://github.com/maksim-101/my-island/releases),
unzip it and move `my-island.app` to `/Applications`. Releases are signed with a Developer ID
and notarized by Apple, so they open without a Gatekeeper warning.

## Build & install from source

```bash
git clone https://github.com/maksim-101/my-island.git
cd my-island
./scripts/install.sh
```

`install.sh` generates the Xcode project from `project.yml`, builds Release, signs, and
installs `my-island.app` to `/Applications`. It runs as a menu-bar-only agent (no Dock
icon). Launch with:

```bash
open /Applications/my-island.app
```

Re-run `./scripts/install.sh` after pulling changes to update the installed app.

### Signing & permissions

The build signs with a **Developer ID** certificate if one is present in your keychain;
otherwise it falls back to **ad-hoc** signing. Ad-hoc signing mints a fresh code hash on
every build, and macOS keys its privacy (TCC) grants to that hash — so with ad-hoc signing
you may have to re-grant Calendar / Accessibility / Automation access after each reinstall.
A stable Developer ID identity keeps grants across rebuilds.

A local `install.sh` build is **not notarized** (only release builds are). If you copy such a
build to another Mac (rather than building it there), Gatekeeper will quarantine it. Clear the quarantine flag before first launch:

```bash
xattr -dr com.apple.quarantine /Applications/my-island.app
```

Accessibility stays **optional**. my-island asks for it only when you turn on Settings -> HUD ->
"Replace the system brightness bezel": the brightness keys then show only my-island's drop, and
my-island changes the brightness itself. The same grant also lets it tell Safari fullscreen video
apart (see "Known Limitations" below). Like the other grants it is forgotten on every ad-hoc
rebuild; you can also grant it by hand in System Settings -> Privacy & Security -> Accessibility.

The volume HUD follows FineTune by default: while FineTune is running my-island hides its own
volume HUD. Settings -> HUD -> "Volume HUD" overrides that with "Always show" or "Never show"
(stored in the `com.myisland.showVolumeHUD` default); "Automatic" removes the override again.

### Diagnostic logging

The installed app writes nothing to the system log by default — that's deliberate, a
privacy/no-noise-in-production policy. For one debugging session, opt in on this machine,
restart the app (the setting is read once at startup), read the log, then restore silence:

```bash
defaults write com.maksim101.myisland MyIslandVerboseLogging -bool YES
# quit and relaunch my-island.app
log show --predicate 'subsystem == "com.maksim101.myisland" AND category == "FullscreenObserver"' --last 10m
defaults delete com.maksim101.myisland MyIslandVerboseLogging
# quit and relaunch my-island.app to restore silence
```

These lines record classification and status facts only — never what's playing, what's on
the calendar, or what was copied.

## Layout

```
Sources/App/        SwiftUI + AppKit app (NSPanel notch overlay, providers, views)
Core/               MyIslandCore SwiftPM package (shared primitives, unit-tested)
Vendor/             Vendored MediaRemote adapter (drives Now Playing)
scripts/            install.sh, release.sh (signed + notarized zip), dev-reset.sh (TCC reset),
                    assert-hud-ownership.sh (HUD invariants), capture-nowplaying.sh, and
                    display/notch probes (display-mode-cycle.swift, notch-clearance-probe.swift)
project.yml         XcodeGen spec — single source of truth for the Xcode project
DESIGN.md           Design tokens (colors, type, spacing) — the app's visual language
```

## Known Limitations

**Chromium-based browsers (Vivaldi, Chrome, Edge, Brave, Arc) never suppress the ambient
row, even when a video is genuinely fullscreen.** Chromium puts the *same* browser window
into macOS fullscreen for both ordinary Spaces-fullscreen browsing and fullscreen video
playback — measured identical window ID, Accessibility subrole, `AXFullScreen` state,
bounds and child roles in both cases, with no distinguishing signal anywhere in the
Accessibility API or the window list. my-island therefore cannot tell the two states apart
in Chromium and defaults to always showing the row there. This is a permanent platform
limitation, not a bug awaiting a future fix — see the project's RESEARCH notes for the full
measured state tables.

**Safari does expose a distinct fullscreen window for video**, so fullscreen video there
correctly hides the ambient row while ordinary Spaces-fullscreen browsing does not. This
discrimination requires the optional Accessibility permission (see "Signing & permissions"
above); without it, Safari behaves like Chromium and the row is never suppressed.

**Non-browser apps (IINA, QuickTime, TV.app, games, slideshows, presentations) hide the
ambient row on ordinary app-level fullscreen** — no Accessibility read is needed for these,
since app-fullscreen alone is a reliable signal for a chromeless, non-browser app.

**Brightness is read through a private, undocumented framework** (`DisplayServices`) —
there is no public API for this on macOS. If a future macOS update breaks the private
symbols this relies on, the brightness HUD row simply hides rather than crashing or
showing stale data.

## License

No license is currently specified. All rights reserved by the author.
