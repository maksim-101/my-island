import AppKit
import Darwin
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
    /// 260911-hx9: the footprint-triggered recycle threshold. Resolved ONCE from the
    /// `MyIslandAdapterFootprintLimitMB` UserDefaults key, mirroring `AppLog.isEnabled`'s
    /// resolve-once convention — an override only takes effect on relaunch. This override exists
    /// so the recycle path can be exercised on hardware without waiting weeks for a real leak to
    /// reproduce; in production the key is unset and this resolves to `AdapterFootprintPolicy`'s
    /// 512 MiB default. `integer(forKey:)` returns `0` for an unset key, which the policy already
    /// maps to the default; `max(0, …)` guards against a negative value written by hand trapping
    /// the `UInt64` conversion.
    private static let footprintLimitBytes: UInt64 = {
        let rawOverride = UserDefaults.standard.integer(forKey: "MyIslandAdapterFootprintLimitMB")
        return AdapterFootprintPolicy.limitBytes(overrideMegabytes: UInt64(max(0, rawOverride)))
    }()
    /// Line delimiter for the adapter's newline-delimited stdout stream (spike 001/002: the bare
    /// empty-state token itself is observed as exactly 4 bytes — `NIL` plus a trailing newline —
    /// which is the strongest available evidence for the delimiter byte).
    private static let lineDelimiter: UInt8 = 0x0A
    /// T-05-03: upper bound on the line-reassembly buffer while no delimiter has arrived yet.
    /// Spike 001 observed a single real payload of 3.2 MB (D-17, base64 artwork), so 8 MiB is
    /// ~2.5x the largest observed legitimate line — generous enough that no real artwork-bearing
    /// payload is ever dropped, finite so an attacker-influenceable field with no embedded
    /// newline (a hostile page's Media Session title, length-unlimited upstream) cannot grow the
    /// buffer without bound.
    private static let maxBufferBytes = 8 * 1024 * 1024

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
    /// 260911-hx9: the ~60s footprint-poll loop, started in `start()` and cancelled in `stop()` —
    /// mirrors `restartTask`'s ownership so quitting the app cannot leave a poll loop alive.
    private var monitorTask: Task<Void, Never>?
    /// 260911-hx9: set immediately before a footprint-triggered `process.terminate()`, read and
    /// cleared at the very top of `handleTermination()` so that funnel can tell a deliberate
    /// recycle apart from a crash.
    private var recyclePending = false

    /// The SINGLE ordered consumer of pipe chunks (see `start()`). The readability handler fires
    /// serially, but the old code handed each chunk to a *separate* `Task { await append }`, and
    /// Swift actor Tasks are not FIFO — so a multi-chunk (150KB–3.2MB) artwork payload was appended
    /// out of order, corrupting the reassembled JSON line and dropping ALL album art as "unparsable"
    /// (UAT 2026-07-31). Draining an order-preserving `AsyncStream` from one task fixes it.
    private var readTask: Task<Void, Never>?
    private var chunkContinuation: AsyncStream<Data>.Continuation?

    private let onUpdate: (NowPlayingModel?) -> Void
    private let logger = AppLog.make("NowPlayingService")

    init(onUpdate: @escaping (NowPlayingModel?) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Resolves the vendored adapter from `Bundle.main`'s `MediaRemoteAdapter` resources
    /// subdirectory (shipped by plan 05-01's `project.yml` folder-reference entry) and launches it.
    /// A `nil` resolution (either file missing) leaves the service unavailable — never a crash.
    /// Returns whether the subprocess was launched successfully.
    @discardableResult
    func start() -> Bool {
        // WR-02: a live subprocess already exists, and relaunching over it would orphan the
        // current Process/Pipe, leaking both the installed readability handler and the reader
        // Task. `true` is the honest return because the caller's question is "is an adapter
        // subprocess running", not "did this call create one".
        guard process == nil else { return true }
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

        // Raw pipe chunks flow through an order-preserving AsyncStream: the serial readability
        // handler only *yields* each chunk (Sendable, no captured mutable state), and a single
        // consumer task below `await append`s them in exact arrival order — so a multi-chunk artwork
        // payload can never be stitched out of order (the corruption that dropped all album art).
        let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.chunkContinuation = chunkContinuation
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // Empty `availableData` signals EOF. The dispatch source is level-triggered, so
                // leaving the handler installed would spin; clear it and end the ordered stream.
                handle.readabilityHandler = nil
                chunkContinuation.finish()
                return
            }
            chunkContinuation.yield(data)
        }
        readTask = Task { [weak self] in
            for await chunk in chunkStream {
                await self?.append(rawChunk: chunk)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        buffer.removeAll()
        self.process = process
        self.pipe = pipe

        do {
            try process.run()
            startFootprintMonitorIfNeeded()
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
        monitorTask?.cancel()
        monitorTask = nil
        recyclePending = false
        readTask?.cancel()
        readTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
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
        // At this point `buffer` holds only an incomplete line with no delimiter in it yet.
        // Dropping mid-line means the tail of that line arrives with the next delimiter and
        // decodes as a single unparsable line, which `process(line:)` already drops silently —
        // no crash, no stale session, and the next complete line recovers normally.
        let pendingByteCount = buffer.count
        if pendingByteCount > Self.maxBufferBytes {
            logger.error("Line-reassembly overflow — dropping \(pendingByteCount, privacy: .public) bytes and resyncing")
            buffer.removeAll()
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

    /// 260911-hx9: starts the ~60s footprint-poll loop, guarded so the restart path started from
    /// `handleTermination()` never stacks a second loop on top of the one already running.
    private func startFootprintMonitorIfNeeded() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(AdapterFootprintPolicy.pollIntervalSeconds))
                // A cancelled sleep returns immediately — re-check before touching any state, the
                // same idiom `handleTermination()`'s restart `Task` already uses, so a cancelled
                // monitor mid-teardown never fires one last check against a torn-down process.
                guard !Task.isCancelled else { return }
                await self?.checkFootprint()
            }
        }
    }

    /// The per-tick check. Reads the adapter child's `ri_phys_footprint` and recycles it above the
    /// resolved limit through the existing crash-restart funnel (`handleTermination()`), without
    /// consuming one of its five bounded restart attempts — a deliberate recycle is not a crash.
    private func checkFootprint() {
        // Between a termination and its backoff restart there is no child to measure — the same
        // window `stop()` already lives with. `process?.isRunning` guards it here too.
        guard let process, process.isRunning else { return }
        guard let bytes = Self.footprintBytes(forPID: process.processIdentifier) else { return }

        let megabytes = bytes / (1024 * 1024)
        let limitMegabytes = Self.footprintLimitBytes / (1024 * 1024)
        // .info, not .debug: unified logging discards .debug messages entirely unless the
        // subsystem was explicitly enabled via `log config`, so a debug-level tick line would be
        // invisible to `log show` after the fact. .info survives in the memory buffer, and there
        // is no noise cost — AppLog already routes everything to OSLog.disabled in Release unless
        // a human opted in on this machine.
        logger.info("Adapter footprint tick: \(megabytes, privacy: .public) MB (limit \(limitMegabytes, privacy: .public) MB)")

        guard AdapterFootprintPolicy.shouldRecycle(footprintBytes: bytes, limitBytes: Self.footprintLimitBytes) else {
            return
        }
        logger.error("Adapter footprint \(megabytes, privacy: .public) MB exceeds limit \(limitMegabytes, privacy: .public) MB — recycling")
        recyclePending = true
        process.terminate()
    }

    /// Reads the adapter child's resident footprint via `proc_pid_rusage`. Touches no actor
    /// state — only the C API — so it's `nonisolated`. Returns `nil` on any non-zero return code;
    /// a failed measurement must never be read as a zero footprint or as a reason to recycle.
    nonisolated private static func footprintBytes(forPID pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard rc == 0 else { return nil }
        return info.ri_phys_footprint
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
        // 260911-hx9: read and clear BEFORE any other state is touched, so the rest of this
        // funnel can tell a deliberate recycle apart from a crash.
        let wasRecycle = recyclePending
        recyclePending = false

        readTask?.cancel()
        readTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pipe = nil
        session = nil
        onUpdate(nil)

        if wasRecycle {
            // A recycle is the supervisor doing its job, not a failure — the restart counter is
            // deliberately left untouched by NOT incrementing it (reset to 0), and the give-up
            // guard below is bypassed entirely. Letting five recycles exhaust the crash-restart
            // budget would convert this safety net into a permanent Now Playing outage, the exact
            // failure it exists to prevent. Routed through the SAME restartTask assignment the
            // crash path uses, so stop()'s existing cancellation still covers it.
            restartAttempts = 0
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.baseBackoffSeconds))
                guard !Task.isCancelled else { return }
                await self?.start()
            }
            return
        }

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
    /// suppression is ear-only and layered on in plan 05-05, not here) — derived directly from
    /// `displayEar` so the invariant can't silently diverge if only one of the two is edited later.
    var displayPanel: Bool { displayEar }

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
    private let logger = AppLog.make("NowPlayingProvider")

    init() {
        Task { await service.start() }
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
