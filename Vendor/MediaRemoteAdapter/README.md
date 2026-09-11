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
| Pinned commit SHA | `5b6afde3f501a3da567e23bf7f23d562938a1809` |
| Build command | `swift build -c release` (run inside a fresh clone checked out at the pinned SHA) |
| Build date | 2026-09-11 |
| Built on | macOS 26.6.2 (build 25G83), arm64 (Apple silicon) |

This re-vendor exists to pick up upstream's fix for a memory leak in the previous pin
(`cf30c4f1…`), which built `CIMediaRemote` with `-fno-objc-arc` while the code was written
ARC-style, so every now-playing JSON payload (including base64 artwork) leaked instead of being
released. A standalone old-vs-new A/B measurement (`/usr/bin/perl run.pl <dylib> loop`, driven
through real Music.app track changes) confirmed the fix: the old dylib's `phys_footprint` grew
18 MB → 38 MB (`MALLOC_SMALL` 4.5 MB → 19 MB) across 62 artwork-bearing events, while the new
dylib stayed flat at 17 MB → 8 MB (peak 19 MB, `MALLOC_SMALL` 4.3 MB → 5.3 MB) across 45 events.
In production, the same leak had grown the adapter child to 4233 MB after 19 days of uptime.

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
