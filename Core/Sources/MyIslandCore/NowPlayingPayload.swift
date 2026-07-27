/// Pure now-playing payload/frame/merge/format layer (MEDIA-01/02/03). No AppKit/Foundation
/// adapter types beyond `Data`/`Date`-adjacent primitives — mirrors `CalendarEventFilter.swift`'s
/// convention of a pure, `Sendable`, unit-testable namespace with no framework dependency beyond
/// `Foundation`. The app layer (`NowPlayingProvider.swift`) adapts the vendored adapter's raw stdout
/// through this layer before anything touches AppKit.
///
/// Field names, the `{type, diff, payload}` wrapper shape, and the empty-state token below are all
/// taken verbatim from `.planning/spikes/002-adapter-stream-mode/README.md` (D-14 evidence) — this
/// project's pinned `ejbills/mediaremote-adapter` fork always sends `diff: false` with a complete
/// payload (RESEARCH.md's Assumption A1 is refuted for this fork), but `merge` still implements the
/// diff-aware contract described below so the code is correct if that ever changes upstream.
import Foundation

/// One decoded now-playing session's fields — all optional because different sources populate
/// different subsets (spike 001/002: Music populates all three of title/artist/album; Safari leaves
/// `album` empty; Infuse leaves `artist`/`album` both `nil`; the Apple TV app leaves `artist` `nil`
/// and puts the show name in `album`).
public struct NowPlayingPayload: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var applicationName: String?
    public var bundleIdentifier: String?
    public var artworkMimeType: String?
    public var isPlaying: Bool?
    public var playbackRate: Double?
    public var elapsedTimeMicros: Double?
    public var durationMicros: Double?
    public var timestampEpochMicros: Double?
    /// Decoded from the payload's base64 `artworkDataBase64` field — raw bytes only, never
    /// `NSImage` (RESEARCH.md Pitfall 3, D-17).
    public var artworkData: Data?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        artworkMimeType: String? = nil,
        isPlaying: Bool? = nil,
        playbackRate: Double? = nil,
        elapsedTimeMicros: Double? = nil,
        durationMicros: Double? = nil,
        timestampEpochMicros: Double? = nil,
        artworkData: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.artworkMimeType = artworkMimeType
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.elapsedTimeMicros = elapsedTimeMicros
        self.durationMicros = durationMicros
        self.timestampEpochMicros = timestampEpochMicros
        self.artworkData = artworkData
    }
}

/// The result of decoding one raw line of adapter stdout (D-16).
public enum NowPlayingFrame: Sendable, Equatable {
    /// The bare empty-state token (spike 001/002: `NIL`, 3 bytes plus a trailing newline) — no
    /// session exists at all.
    case empty
    /// A successfully decoded session event. `isDiff` mirrors the wrapper's `diff` field verbatim
    /// (always `false` for the pinned fork per spike 002, but the field is still read rather than
    /// ignored, so `merge` stays correct if that ever changes).
    case session(payload: NowPlayingPayload, isDiff: Bool)
    /// A line that was neither the empty token nor valid JSON — dropped by the caller, never a
    /// thrown/trapped decode failure (D-16, V5 input validation: adapter stdout is untrusted).
    case unparsable
}

/// Decodes raw adapter stdout lines and merges session state across events (D-16, MEDIA-03).
public enum NowPlayingDiffMerger {
    /// The adapter's true empty-state token, observed identically for both one-shot `get` and
    /// persistent `loop` modes (spike 002, Design consequence 5) — three raw bytes, not JSON.
    private static let emptyToken = "NIL"

    /// Decodes one raw line of adapter stdout. Checks the bare empty-state token BEFORE attempting
    /// any JSON decode (D-16) — trims surrounding whitespace/newlines first so a trailing `\n` from
    /// the line-delimited stream never defeats the check. Any JSON decode failure maps to
    /// `.unparsable`, never a thrown error that escapes to the caller (adapter stdout is untrusted
    /// third-party app metadata — V5 input validation).
    public static func decode(rawLine: Data) -> NowPlayingFrame {
        guard let text = String(data: rawLine, encoding: .utf8) else {
            return .unparsable
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unparsable
        }
        if trimmed == emptyToken {
            return .empty
        }

        guard let jsonData = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: jsonData) else {
            return .unparsable
        }

        let dto = envelope.payload
        let artworkData = dto.artworkDataBase64.flatMap { Data(base64Encoded: $0) }
        let payload = NowPlayingPayload(
            title: dto.title,
            artist: dto.artist,
            album: dto.album,
            applicationName: dto.applicationName,
            bundleIdentifier: dto.bundleIdentifier,
            artworkMimeType: dto.artworkMimeType,
            isPlaying: dto.isPlaying,
            playbackRate: dto.playbackRate,
            elapsedTimeMicros: dto.elapsedTimeMicros,
            durationMicros: dto.durationMicros,
            timestampEpochMicros: dto.timestampEpochMicros,
            artworkData: artworkData
        )
        return .session(payload: payload, isDiff: envelope.diff ?? false)
    }

    /// Merges an incoming payload onto the previously held session state. When `isDiff` is `true`
    /// and a previous state exists, a `nil` field on `incoming` keeps `previous`'s value — nothing
    /// absent from a partial event is treated as cleared. Otherwise `incoming` replaces the state
    /// wholesale (including dropping artwork the new event omits) — this is the branch the pinned
    /// fork actually exercises today (spike 002: `diff` is always `false`), but the diff-merge
    /// branch is implemented in full so the code stays correct if that ever changes.
    public static func merge(previous: NowPlayingPayload?, incoming: NowPlayingPayload, isDiff: Bool) -> NowPlayingPayload {
        guard isDiff, let previous else {
            return incoming
        }
        return NowPlayingPayload(
            title: incoming.title ?? previous.title,
            artist: incoming.artist ?? previous.artist,
            album: incoming.album ?? previous.album,
            applicationName: incoming.applicationName ?? previous.applicationName,
            bundleIdentifier: incoming.bundleIdentifier ?? previous.bundleIdentifier,
            artworkMimeType: incoming.artworkMimeType ?? previous.artworkMimeType,
            isPlaying: incoming.isPlaying ?? previous.isPlaying,
            playbackRate: incoming.playbackRate ?? previous.playbackRate,
            elapsedTimeMicros: incoming.elapsedTimeMicros ?? previous.elapsedTimeMicros,
            durationMicros: incoming.durationMicros ?? previous.durationMicros,
            timestampEpochMicros: incoming.timestampEpochMicros ?? previous.timestampEpochMicros,
            artworkData: incoming.artworkData ?? previous.artworkData
        )
    }

    /// The `{type, diff, payload}` wrapper shape, field names verbatim from spike 002.
    private struct Envelope: Decodable {
        let type: String?
        let diff: Bool?
        let payload: PayloadDTO
    }

    /// The payload object's keys, verbatim from spike 002's observed field list.
    private struct PayloadDTO: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let applicationName: String?
        let bundleIdentifier: String?
        let artworkMimeType: String?
        let isPlaying: Bool?
        let playbackRate: Double?
        let elapsedTimeMicros: Double?
        let durationMicros: Double?
        let timestampEpochMicros: Double?
        let artworkDataBase64: String?
    }
}

/// The ear's "Title — Artist" text formatter (D-02, UI-SPEC Copywriting Contract).
public enum NowPlayingFormatting {
    /// Joins title and artist with a literal em dash surrounded by single spaces, omitting the
    /// separator (and never leaving it dangling) when either side is `nil` or empty. Handles a
    /// `nil` artist identically to an empty one — spike 002 observed `artist: null` (not `""`) for
    /// both Infuse and the Apple TV app, so a formatter that only special-cased empty strings would
    /// render a bare title correctly for Music/Safari but silently regress for video sources.
    public static func earText(title: String?, artist: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch (trimmedTitle.isEmpty, trimmedArtist.isEmpty) {
        case (false, false):
            return "\(trimmedTitle) — \(trimmedArtist)"
        case (false, true):
            return trimmedTitle
        case (true, false):
            return trimmedArtist
        case (true, true):
            return ""
        }
    }
}
