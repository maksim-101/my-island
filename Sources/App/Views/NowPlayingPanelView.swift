import SwiftUI
import AppKit
import MyIslandCore

/// The Now Playing detail droplet (07-DESIGN-AGREEMENT.md §4, sketch `DETAIL.np`,
/// `.planning/sketches/006-design-round/index.html:641-647`): artwork, title/artist, output
/// device, a progress bar with elapsed/remaining time, and previous/play-pause/next transport
/// (MEDIA-04/05) — no scrolling or marquee text anywhere (07-09-PLAN's own prohibition; the old
/// scrolling-track-text view this file used is deleted outright, not superseded).
/// Has NO internal empty branch for the artwork/title row: per D-12 the row still renders with
/// "Not playing" placeholders when there is no session — the module stays visible in the band and
/// its droplet must render something coherent when opened either way.
@MainActor
struct NowPlayingPanelView: View {
    let nowPlaying: NowPlayingProvider

    @State private var outputDeviceName: String?

    private static let artworkSize: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                ArtworkTile(artwork: nowPlaying.artwork, size: Self.artworkSize, cornerRadius: 9)

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(artistAlbumText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.Color.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let outputDeviceName {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 9))
                            Text(outputDeviceName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Tokens.Color.textFaint)
                        .padding(.top, 2)
                    }
                }
            }

            Spacer(minLength: Tokens.Spacing.xs)

            // Omitted entirely (no indeterminate/looping animation) when the payload carries no
            // usable duration — a live stream with no fixed length — per UI-SPEC's "omit rather
            // than fake" convention.
            if let fraction = nowPlaying.elapsedFraction {
                VStack(spacing: 4) {
                    NowPlayingProgressBar(fraction: fraction)
                    if let times = elapsedRemainingText {
                        HStack {
                            Text(times.elapsed)
                            Spacer()
                            Text(times.remaining)
                        }
                        .font(.system(size: 10, weight: .regular).monospaced())
                        .foregroundStyle(Tokens.Color.textFaint)
                    }
                }
            }

            controlsRow
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, Tokens.Spacing.xs)
        }
        // UI-SPEC "Paused-in-grace": the whole stage — including the progress bar frozen at
        // its last known position — dims to 55% opacity during the 30s grace window, matching the
        // ear's identical treatment.
        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
        .task {
            outputDeviceName = AudioOutputDevice.currentName()
        }
    }

    private var titleText: String {
        let title = nowPlaying.currentModel?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Not playing" : title
    }

    private var artistAlbumText: String {
        let artist = nowPlaying.currentModel?.artist.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = nowPlaying.currentModel?.album.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (artist.isEmpty, album.isEmpty) {
        case (false, false): return "\(artist) \u{00B7} \(album)"
        case (false, true): return artist
        case (true, false): return album
        case (true, true): return "\u{2014}"
        }
    }

    /// Elapsed/remaining clock text (10pt mono, sketch's "2:48"/"−1:57"). Derived from the
    /// provider's already-ticking `elapsedFraction` (updated once per second, D-08) times the
    /// model's own duration — no separate raw-microseconds recomputation needed here.
    private var elapsedRemainingText: (elapsed: String, remaining: String)? {
        guard let fraction = nowPlaying.elapsedFraction,
              let durationMicros = nowPlaying.currentModel?.durationMicros,
              durationMicros > 0 else { return nil }
        let durationSeconds = durationMicros / 1_000_000
        let elapsedSeconds = fraction * durationSeconds
        let remainingSeconds = max(0, durationSeconds - elapsedSeconds)
        return (Self.clockText(elapsedSeconds), "\u{2212}" + Self.clockText(remainingSeconds))
    }

    private static func clockText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var controlsRow: some View {
        HStack(spacing: Tokens.Spacing.md) {
            transportButton(systemName: "backward.fill", command: .previousTrack, diameter: 26, help: "Previous", index: 0)
            playPauseButton
            transportButton(systemName: "forward.fill", command: .nextTrack, diameter: 26, help: "Next", index: 2)
        }
        .disabled(nowPlaying.currentModel == nil)
    }

    private func transportButton(systemName: String, command: NowPlayingCommand, diameter: CGFloat, help: String, index: Int) -> some View {
        Button {
            nowPlaying.send(command)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Color.text)
                .frame(width: diameter, height: diameter)
                .background(Tokens.Color.surfaceRaised)
                .clipShape(Circle())
        }
        .buttonStyle(GlyphButtonStyle())
        .help(help)
        .dropletFocusable(index: index, ring: .circle) { nowPlaying.send(command) }
    }

    private var playPauseButton: some View {
        Button {
            nowPlaying.send(.togglePlayPause)
        } label: {
            Image(systemName: nowPlaying.isPlayingForDisplay ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.Color.accentInk)
                .frame(width: 34, height: 34)
                .background(Tokens.Color.accent)
                .clipShape(Circle())
        }
        .buttonStyle(GlyphButtonStyle())
        .help(nowPlaying.isPlayingForDisplay ? "Pause" : "Play")
        .dropletFocusable(index: 1, ring: .circle) { nowPlaying.send(.togglePlayPause) }
    }
}

/// The droplet's progress bar (D-08): a 2pt-tall hairline `Capsule` track with an `accent`
/// fill sized to `fraction` of the available width, measured via `GeometryReader` so it spans the
/// content column exactly.
private struct NowPlayingProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tokens.Color.hairline)
                Capsule()
                    .fill(Tokens.Color.accent)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 2)
    }
}
