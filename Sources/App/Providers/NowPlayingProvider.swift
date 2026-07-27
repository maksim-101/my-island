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
    /// The pending backoff-restart `Task` scheduled by `handleTermination()` — stored so `stop()` can
    /// cancel it. Without this, `stop()` clears `process`/`pipe` (already `nil` by the time a restart
    /// is pending) but has no handle on the scheduled `Task.sleep` + `start()` call, so a crash-then-
    /// quit sequence can relaunch the subprocess after the app has told it to stop.
    private var restartTask: Task<Void, Never>?

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
            guard !data.isEmpty else {
                // Empty `availableData` signals EOF. The dispatch source backing
                // `readabilityHandler` is level-triggered, so leaving the handler installed here
                // would keep firing back-to-back for as long as the fd stays open and un-drained —
                // clear it so an EOF-without-immediate-exit can't spin the read queue.
                handle.readabilityHandler = nil
                return
            }
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
    /// Also cancels any pending backoff-restart `Task` so a subprocess crash immediately before quit
    /// cannot relaunch the adapter after the app has already asked it to stop.
    func stop() {
        restartTask?.cancel()
        restartTask = nil
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
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
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

/// Mirrors `CalendarProvider`'s `@MainActor @Observable` shape. Owns the grace/stale rules
/// (D-06/D-07/D-12): every model update — including the adapter's own empty state — is classified by
/// `NowPlayingSessionClassifier`, and `displayEar`/`displayPanel`/`isPausedInGrace` read the result.
@MainActor
@Observable
final class NowPlayingProvider {
    private(set) var currentModel: NowPlayingModel?
    private(set) var artwork: NSImage?
    private(set) var isAvailable: Bool = true

    /// The expanded-panel progress-bar fill fraction (D-08), computed via `NowPlayingElapsed` from
    /// `currentModel`'s elapsed/timestamp/rate/duration fields — `nil` when there is no session or
    /// no usable duration, which `NowPlayingPanelView` reads as "omit the bar entirely." Recomputed
    /// on every model update AND on a cheap 1-second tick (below) so the bar advances smoothly
    /// between the adapter's own (non-per-second) events rather than sitting still and jumping.
    private(set) var elapsedFraction: Double?

    /// The classifier's current verdict (D-06/D-07/D-12) — the single source of truth `displayEar`,
    /// `displayPanel` and `isPausedInGrace` all read from.
    private(set) var classification = NowPlayingClassification(visibility: .hidden, graceDeadline: nil)
    /// The identity the current `classification` was computed against — passed back into `classify`
    /// on the next update so a different session never inherits this one's grace deadline.
    private var currentIdentity: NowPlayingSessionIdentity?
    /// Grace deadline arithmetic lives entirely in `NowPlayingSessionClassifier.classify` — this file
    /// only schedules a `DispatchWorkItem` for `NowPlayingSessionClassifier.gracePeriod`'s window and
    /// re-runs that same pure `classify()` call when it fires; it defines no competing grace constant
    /// of its own. `nonisolated(unsafe)` + `deinit` cancellation mirrors `CalendarProvider`'s timer
    /// convention for anything a `@MainActor` provider schedules onto a queue.
    nonisolated(unsafe) private var pendingGraceExpiry: DispatchWorkItem?

    /// Recomputes `elapsedFraction` from the cached `currentModel` only — never re-reads the
    /// adapter (T-05-13). Started only while `classification.visibility == .playing` and stopped
    /// for `.pausedInGrace`/`.hidden` (see `updateProgressTick`), so the bar freezes during the
    /// grace window and nothing ticks at idle. `nonisolated(unsafe)` + `deinit` invalidation
    /// mirrors `CalendarProvider`'s `tickTimer` convention.
    nonisolated(unsafe) private var progressTickTimer: Timer?

    /// Drives `NotchBarView`'s D-05 disjunction gate — true while the session is playing or within
    /// its post-stop grace window (D-06/D-07), false once it is hidden.
    var displayEar: Bool {
        classification.visibility != .hidden
    }

    /// The expanded panel group follows the SAME grace as the ear (assumptions block: fullscreen
    /// suppression is ear-only and layered on in plan 05-05, not here).
    var displayPanel: Bool {
        classification.visibility != .hidden
    }

    /// Drives the ear's 55% opacity dim and frozen scroll (UI-SPEC "Paused-in-grace visual
    /// distinction").
    var isPausedInGrace: Bool {
        classification.visibility == .pausedInGrace
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

    /// Applies a model update from the service: builds the session identity, classifies it against
    /// the previous classification/identity (D-06/D-07/D-12), then hands off to `handle` for the
    /// shared model/artwork/scheduling side effects.
    private func apply(model: NowPlayingModel?) {
        let identity = model.map {
            NowPlayingSessionIdentity(bundleIdentifier: $0.bundleIdentifier, title: $0.title, artist: $0.artist)
        }
        let newClassification = NowPlayingSessionClassifier.classify(
            identity: identity,
            isPlaying: model?.isPlaying ?? false,
            previous: classification,
            previousIdentity: currentIdentity,
            now: Date()
        )
        handle(newClassification: newClassification, identity: identity, model: model)
    }

    /// Re-runs the classifier at the current instant against the SAME session identity and its
    /// last-known non-playing state — the grace expiry goes through the exact same pure rules as
    /// every other transition rather than a hand-rolled "just hide it" shortcut. Any resume in the
    /// meantime already went through `apply(model:)`, which cancelled and replaced this work item, so
    /// this only ever fires for a session that is still not playing.
    private func reEvaluateGraceExpiry(identity: NowPlayingSessionIdentity?) {
        let newClassification = NowPlayingSessionClassifier.classify(
            identity: identity,
            isPlaying: false,
            previous: classification,
            previousIdentity: currentIdentity,
            now: Date()
        )
        handle(newClassification: newClassification, identity: identity, model: currentModel)
    }

    /// Shared side effects for a freshly computed classification: decodes `artwork` from
    /// `artworkData` via `NSImage(data:)` ONLY when the bytes differ from the previously decoded
    /// bytes (cheap `Data` equality check first) — this is the one and only decode site, on the main
    /// actor (D-17, RESEARCH.md Pitfall 3) — clears both `currentModel` and `artwork` the moment the
    /// session goes hidden (no stale bytes retained, D-17), stores the new classification/identity,
    /// (re)schedules the grace-expiry work item, and logs the transition by visibility name only —
    /// never a title, artist, album or source-app name (T-05-02).
    private func handle(newClassification: NowPlayingClassification, identity: NowPlayingSessionIdentity?, model: NowPlayingModel?) {
        if newClassification.visibility == .hidden {
            currentModel = nil
            artwork = nil
        } else if let model {
            if model.artworkData != currentModel?.artworkData {
                artwork = model.artworkData.flatMap { NSImage(data: $0) }
            }
            currentModel = model
        }

        classification = newClassification
        currentIdentity = identity
        scheduleGraceExpiry(identity: identity)
        updateElapsedFraction()
        updateProgressTick(for: newClassification.visibility)

        logger.debug("Now Playing visibility transition — visibility=\(String(describing: newClassification.visibility), privacy: .public)")
    }

    /// Recomputes `elapsedFraction` from `currentModel`'s cached elapsed/timestamp/rate/duration
    /// fields via `NowPlayingElapsed`. When `currentModel` is `isPlaying == false` (paused-in-grace
    /// or a session that simply isn't playing), `NowPlayingElapsed.currentMicros` already returns
    /// the snapshot's elapsed value unchanged — so calling this again while paused naturally holds
    /// the bar at its last known position rather than requiring separate freeze logic here.
    private func updateElapsedFraction() {
        guard let currentModel else {
            elapsedFraction = nil
            return
        }
        let micros = NowPlayingElapsed.currentMicros(
            elapsedTimeMicros: currentModel.elapsedTimeMicros,
            timestampEpochMicros: currentModel.timestampEpochMicros,
            playbackRate: currentModel.playbackRate,
            isPlaying: currentModel.isPlaying,
            now: Date()
        )
        elapsedFraction = NowPlayingElapsed.fraction(elapsedMicros: micros, durationMicros: currentModel.durationMicros)
    }

    /// Starts the progress tick only while actually playing; stops it for paused-in-grace or
    /// hidden — there is nothing to interpolate forward in either of those states, and running the
    /// tick anyway would just be wasted CPU (T-05-13).
    private func updateProgressTick(for visibility: NowPlayingVisibility) {
        switch visibility {
        case .playing:
            startProgressTickIfNeeded()
        case .pausedInGrace, .hidden:
            stopProgressTick()
        }
    }

    private func startProgressTickIfNeeded() {
        guard progressTickTimer == nil else { return }
        progressTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsedFraction() }
        }
    }

    private func stopProgressTick() {
        progressTickTimer?.invalidate()
        progressTickTimer = nil
    }

    /// `HUDViewModel`'s cancel-then-reschedule `DispatchWorkItem` idiom: cancel any pending expiry
    /// first, then — only when the current classification is paused-in-grace with a deadline — build
    /// a new work item and dispatch it after the remaining interval. A resume inside the window (a
    /// fresh `apply(model:)` call) cancels this before it ever fires; a different session's arrival
    /// replaces it outright.
    private func scheduleGraceExpiry(identity: NowPlayingSessionIdentity?) {
        pendingGraceExpiry?.cancel()
        pendingGraceExpiry = nil

        guard classification.visibility == .pausedInGrace, let deadline = classification.graceDeadline else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.reEvaluateGraceExpiry(identity: identity)
        }
        pendingGraceExpiry = workItem
        let delay = max(0, deadline.timeIntervalSince(Date()))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Stops the adapter subprocess — called from `AppDelegate` at quit, mirroring the app's other
    /// providers' teardown expectations.
    func stopService() {
        Task { await service.stop() }
    }

    deinit {
        pendingGraceExpiry?.cancel()
        progressTickTimer?.invalidate()
    }
}
