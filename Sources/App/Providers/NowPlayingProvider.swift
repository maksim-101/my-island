import AppKit
import Foundation
import OSLog
import MyIslandCore

/// Owns the vendored adapter subprocess (D-13: runs for the app's whole lifetime), decodes and
/// merges its stdout via `NowPlayingDiffMerger`, and projects the merged session to the `Sendable`
/// `NowPlayingModel` — never letting raw adapter bytes or `NSImage` cross the actor boundary
/// (RESEARCH.md Pattern 1/2, Pitfall 3). Mirrors `CalendarProvider.swift`'s `CalendarService` actor
/// shape, but is push- rather than pull-driven: the adapter is a persistent event stream, so state
/// changes are handed to the `@MainActor` provider via an injected callback rather than awaited from
/// a discrete request.
actor NowPlayingService {
    /// Persistent-mode subcommand string, taken verbatim from spike 002 (05-01 evidence) — this is
    /// the pinned fork's actual CLI subcommand, not upstream's `stream`.
    private static let persistentModeCommand = "loop"
    /// D-15: bounded restart attempts with growing delay, then silent give-up — mirrors
    /// `HUDViewModel`'s cancel-then-reschedule idiom, applied to retry scheduling instead of fade
    /// scheduling (RESEARCH.md Code Examples).
    private static let maxRestartAttempts = 5
    private static let baseBackoffSeconds: TimeInterval = 1.0
    /// Line delimiter for the adapter's newline-delimited stdout stream (spike 001/002: the bare
    /// empty-state token itself is observed as exactly 4 bytes — `NIL` plus a trailing newline —
    /// which is the strongest available evidence for the delimiter byte).
    private static let lineDelimiter: UInt8 = 0x0A

    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var session: NowPlayingPayload?
    private var restartAttempts = 0

    private let onUpdate: (NowPlayingModel?) -> Void
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "NowPlayingService")

    init(onUpdate: @escaping (NowPlayingModel?) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Resolves the vendored adapter from `Bundle.main`'s `MediaRemoteAdapter` resources
    /// subdirectory (shipped by plan 05-01's `project.yml` folder-reference entry) and launches it.
    /// A `nil` resolution (either file missing) leaves the service unavailable — never a crash.
    /// Returns whether the subprocess was launched successfully.
    @discardableResult
    func start() -> Bool {
        guard let resourceURL = Bundle.main.resourceURL else {
            logger.error("No bundle resource URL — Now Playing unavailable")
            return false
        }
        let adapterDirectory = resourceURL.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
        let scriptURL = adapterDirectory.appendingPathComponent("run.pl")
        let dylibURL = adapterDirectory.appendingPathComponent("libMediaRemoteAdapter.dylib")

        guard FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: dylibURL.path) else {
            logger.error("Vendored adapter files not found in bundle resources — Now Playing unavailable")
            return false
        }

        // Exactly three literal arguments: two bundle-resolved absolute paths and a literal mode
        // string. No decoded adapter field ever reaches a Process argument (T-05-01).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, dylibURL.path, Self.persistentModeCommand]

        let pipe = Pipe()
        process.standardOutput = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Re-enters actor isolation via Task — never mutate actor state from this
            // non-isolated closure context directly (Swift 6 strict concurrency).
            Task { await self?.append(rawChunk: data) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        buffer.removeAll()
        self.process = process
        self.pipe = pipe

        do {
            try process.run()
            return true
        } catch {
            logger.error("Failed to launch adapter subprocess")
            self.process = nil
            self.pipe = nil
            return false
        }
    }

    /// Clears the readability handler, terminates the process, and nils both — used at app quit.
    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        pipe = nil
    }

    /// Buffers incoming bytes and splits on the newline line delimiter so a payload larger than one
    /// read chunk (spike 001 observed a 3.2 MB payload; D-17) is reassembled before decoding.
    private func append(rawChunk: Data) {
        buffer.append(rawChunk)
        while let delimiterIndex = buffer.firstIndex(of: Self.lineDelimiter) {
            let lineData = buffer[..<delimiterIndex]
            let consumed = buffer.index(after: delimiterIndex)
            buffer.removeSubrange(buffer.startIndex..<consumed)
            guard !lineData.isEmpty else { continue }
            process(line: Data(lineData))
        }
    }

    private func process(line: Data) {
        switch NowPlayingDiffMerger.decode(rawLine: line) {
        case .empty:
            session = nil
            publish()
        case .session(let payload, let isDiff):
            session = NowPlayingDiffMerger.merge(previous: session, incoming: payload, isDiff: isDiff)
            publish()
        case .unparsable:
            // Byte count only — never the line's content (T-05-02: no adapter metadata in logs).
            logger.info("Adapter emitted an unparsable line (\(line.count, privacy: .public) bytes) — dropped")
        }
    }

    /// A successful decode (even an empty-state one) counts as a live, communicating subprocess —
    /// resets the restart counter per D-15's "a successful read after a restart resets the count."
    private func publish() {
        restartAttempts = 0
        onUpdate(session.map(Self.project))
    }

    private static func project(_ payload: NowPlayingPayload) -> NowPlayingModel {
        NowPlayingModel(
            title: payload.title ?? "",
            artist: payload.artist ?? "",
            album: payload.album ?? "",
            applicationName: payload.applicationName ?? "",
            bundleIdentifier: payload.bundleIdentifier ?? "",
            isPlaying: payload.isPlaying ?? false,
            playbackRate: payload.playbackRate ?? 0,
            elapsedTimeMicros: payload.elapsedTimeMicros,
            durationMicros: payload.durationMicros,
            timestampEpochMicros: payload.timestampEpochMicros,
            artworkData: payload.artworkData,
            artworkMimeType: payload.artworkMimeType
        )
    }

    /// D-15: on subprocess death, clear the published session immediately (the ear/panel must go
    /// silent, not show stale content), then restart with a growing delay up to a bounded maximum;
    /// at the maximum, log once and stop — no further attempts, no user-visible error anywhere.
    private func handleTermination() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pipe = nil
        session = nil
        onUpdate(nil)

        guard restartAttempts < Self.maxRestartAttempts else {
            logger.error("Adapter subprocess exhausted \(Self.maxRestartAttempts, privacy: .public) restart attempts — giving up silently")
            return
        }
        let attempt = restartAttempts
        restartAttempts += 1
        let delay = Self.baseBackoffSeconds * pow(2.0, Double(attempt))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.start()
        }
    }
}

/// `Sendable` projection crossing the actor boundary — artwork as raw bytes only, never `NSImage`
/// (RESEARCH.md Pitfall 3, D-17). String fields are empty-string-normalised (never optional) since
/// `NowPlayingFormatting.earText` already treats empty/nil identically and the view layer only ever
/// needs a concrete `String` to render.
struct NowPlayingModel: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String
    let applicationName: String
    let bundleIdentifier: String
    let isPlaying: Bool
    let playbackRate: Double
    let elapsedTimeMicros: Double?
    let durationMicros: Double?
    let timestampEpochMicros: Double?
    let artworkData: Data?
    let artworkMimeType: String?
}

/// Mirrors `CalendarProvider`'s `@MainActor @Observable` shape. Owns the grace/stale rules'
/// eventual home (D-06/D-07 land in plan 05-03 and extend `displayEar`) — for this tracer slice,
/// the ear shows exactly when a session exists and is playing.
@MainActor
@Observable
final class NowPlayingProvider {
    private(set) var currentModel: NowPlayingModel?
    private(set) var artwork: NSImage?
    private(set) var isAvailable: Bool = true

    /// Drives `NotchBarView`'s D-05 disjunction gate. Grace/stale extensions land in plan 05-03.
    var displayEar: Bool {
        currentModel?.isPlaying == true
    }

    // `@ObservationIgnored`: a `lazy var` whose initializer closure captures
    // `self` cannot also be macro-expanded by `@Observable`'s
    // `ObservationTracked` accessor synthesis ("class declaration cannot
    // close over value 'self' defined in outer scope") — and this is a
    // private implementation detail the view layer never reads directly, so
    // it should not be observed anyway.
    @ObservationIgnored
    private lazy var service = NowPlayingService { [weak self] model in
        Task { @MainActor in
            self?.apply(model: model)
        }
    }
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "NowPlayingProvider")

    init() {
        Task {
            let started = await service.start()
            isAvailable = started
        }
    }

    /// Applies a model update from the service. Decodes `artwork` from `artworkData` via
    /// `NSImage(data:)` ONLY when the bytes differ from the previously decoded bytes (cheap `Data`
    /// equality check first) — this is the one and only decode site, on the main actor (D-17,
    /// RESEARCH.md Pitfall 3). A nil decode result is treated exactly like "no artwork."
    private func apply(model: NowPlayingModel?) {
        guard let model else {
            currentModel = nil
            artwork = nil
            return
        }
        if model.artworkData != currentModel?.artworkData {
            artwork = model.artworkData.flatMap { NSImage(data: $0) }
        }
        currentModel = model
        // Status, byte counts, attempt numbers only — never a title, artist, album or
        // application-name value (T-05-02).
        logger.debug("Now Playing model updated — isPlaying=\(model.isPlaying, privacy: .public), artworkBytes=\(model.artworkData?.count ?? 0, privacy: .public)")
    }

    /// Stops the adapter subprocess — called from `AppDelegate` at quit, mirroring the app's other
    /// providers' teardown expectations.
    func stopService() {
        Task { await service.stop() }
    }
}
