# my-island

A native macOS notch app for the 16-inch MacBook Pro — an **actionable-first** companion
for the camera-housing notch. The collapsed notch always shows live ambient state; it
expands on hover or a global hotkey into a panel for timers, clipboard, and (planned)
calendar and a Claude Code "needs you" strip.

Actionable, not decorative — the notch surfaces what needs your attention and lets you act
on it (or jump straight to it) without switching windows.

> Built as a personal daily-driver. It is hardcoded to the 16" MacBook Pro notch and
> targets **macOS Tahoe (26.x)**. It degrades to a top-center floating pill on displays
> with no notch, but it is not designed or tested for other hardware.

## Status

**Version 0.1.0 — in active development.** Not all features are built yet.

| Area | State |
|------|-------|
| Notch shell (always-on collapsed state, hover-to-expand, global hotkey) | Built; on-device verification ongoing |
| Timers / focus (pomodoro + countdown) | ✅ Working |
| Brightness + volume HUD | ✅ Working |
| Clipboard history (10 entries, password-manager copies skipped) | ✅ Working |
| Own visual design language ([`DESIGN.md`](DESIGN.md)) | ✅ Working |
| Calendar next-meeting countdown + one-click join | Implemented; UAT pending |
| Now Playing (Apple Music + browser audio) | Not built yet |
| Downloads / transfers progress | Backlogged |
| Claude Code "needs you" strip | Not built yet |

## Requirements

- 16-inch MacBook Pro (or any Mac with a notch) running **macOS 26 (Tahoe)** or later
- **Xcode 26** (Tahoe SDK) with command-line tools
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Build & install

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

The app is **not notarized**. If you copy a build to another Mac (rather than building it
there), Gatekeeper will quarantine it. Clear the quarantine flag before first launch:

```bash
xattr -dr com.apple.quarantine /Applications/my-island.app
```

## Layout

```
Sources/App/        SwiftUI + AppKit app (NSPanel notch overlay, providers, views)
Core/               MyIslandCore SwiftPM package (shared primitives, unit-tested)
Vendor/             Vendored MediaRemote adapter (Now Playing, planned)
scripts/            install.sh, dev-reset.sh (TCC reset), capture-nowplaying.sh
project.yml         XcodeGen spec — single source of truth for the Xcode project
DESIGN.md           Design tokens (colors, type, spacing) — the app's visual language
```

## License

No license is currently specified. All rights reserved by the author.
