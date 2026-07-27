# Vendored: mediaremote-adapter

This directory contains a **vendored, pinned-commit copy** of the perl script + compiled dylib from
`ejbills/mediaremote-adapter` (a maintained fork of `ungive/mediaremote-adapter`). It is the only viable
path to reading system-wide Now Playing metadata (title/artist/artwork/play-state) from a third-party
macOS app since Apple restricted in-process `MRMediaRemoteGetNowPlayingInfo` access starting macOS 15.4
(see `.claude/CLAUDE.md` "What NOT to Use" and `.planning/spikes/001-mediaremote-adapter/README.md`).

## Provenance

| Field | Value |
|-------|-------|
| Repo URL | https://github.com/ejbills/mediaremote-adapter |
| Upstream (fork origin) | https://github.com/ungive/mediaremote-adapter |
| Pinned commit SHA | `cf30c4f1af29b5829d859f088f8dbdf12611a046` |
| Build command | `swift build -c release` (run inside a fresh clone checked out at the pinned SHA) |
| Build date | 2026-07-27 |
| Built on | macOS 26.5.2 (build 25F84), arm64 (Apple silicon) |

## Resolved files

- `run.pl` — the adapter's perl entry-point script (originally
  `Sources/MediaRemoteAdapter/Resources/run.pl` in the upstream package; copied here under its original
  file name).
- `libMediaRemoteAdapter.dylib` — the compiled dynamic library the perl script loads, built for `arm64`
  from the pinned commit via `swift build -c release`.

## Standing instructions

**This is a workaround for a deliberate Apple restriction, not a stable dependency.** Re-test this
vendored copy after every macOS point release (the read path, and specifically the `stream`/`loop`-mode
behaviour this phase depends on) — Apple has tightened MediaRemote access before and can do so again with
no warning.

**Vendoring decision (re-affirmed, not re-opened):** this adapter is deliberately vendored as raw script +
dylib, invoked as a subprocess via `/usr/bin/perl`, rather than added to `project.yml`'s `packages:` block
as a linked SPM dependency. That decision is locked in `.claude/CLAUDE.md`'s Technology Stack section
(D-19 in `.planning/phases/05-now-playing/05-CONTEXT.md`); this plan does not re-open it.
