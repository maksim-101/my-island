import Darwin
import Foundation
import OSLog
import MyIslandCore

/// CLAUDE-01/02/03 (pulled forward from v2, 07-14): a read-only, 3s-polled view of
/// `~/.claude/statusbar/state.d` — the same untrusted per-session files the statusbar hook
/// (`session-state.sh`) writes for CCMetrics' own Sessions card (T-07-20/T-07-22: this provider
/// never writes, renames or deletes anything in that directory; only `Data(contentsOf:)` reads).
/// Mirrors `ClipboardViewModel`'s own `Timer`-poll convention (no push notification exists for
/// either pasteboard changes or hook-file writes), but does the actual directory listing/decoding
/// off the main actor (`Task.detached`) since it's disk I/O across an arbitrary number of files,
/// then hops back to publish `sessions` — unlike `ClipboardViewModel`'s single, cheap
/// `changeCount` read.
@MainActor
@Observable
final class ClaudeSessionsProvider {
    /// Sorted (`ClaudeSessions.sorted`), stale/dead-process/oversized/symlinked entries already
    /// excluded — `BandView`/`ClaudePanelView` read this directly, never the raw directory.
    private(set) var sessions: [ClaudeSession] = []

    /// The sessions the band's amber badge/glyph react to (`needsYou`) — already sorted, so
    /// `.first` is the longest-waiting one (07-DESIGN-AGREEMENT.md §4).
    var waiting: [ClaudeSession] { sessions.filter { $0.status.needsYou } }

    var waitingCount: Int { ClaudeSessions.waitingCount(sessions) }

    private let directoryURL: URL
    private let logger = AppLog.make("ClaudeSessionsProvider")
    /// Accessed from `deinit`, which runs nonisolated — `Timer.invalidate()` is thread-agnostic
    /// and no other isolated state is touched there, mirroring `ClipboardViewModel.pollTimer`.
    nonisolated(unsafe) private var pollTimer: Timer?
    /// Logs `claudeSessions count=<n> waiting=<m>` only when either number actually changes — a
    /// steady-state poll with nothing new produces zero log lines, matching this app's own
    /// "silent unless something changed" logging convention elsewhere (`reconcile`, `fullscreenState`).
    private var lastLoggedCount: Int?
    private var lastLoggedWaiting: Int?

    init(directoryURL: URL = ClaudeSessionsProvider.defaultDirectoryURL) {
        self.directoryURL = directoryURL
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/statusbar/state.d", isDirectory: true)
    }

    /// `NotchPanelController.openBand` calls this so the band never opens showing data up to 3s
    /// stale from the last poll tick.
    func refreshNow() {
        refresh()
    }

    private func refresh() {
        let directoryURL = self.directoryURL
        Task.detached(priority: .utility) {
            let sorted = Self.readAndSort(directoryURL: directoryURL, now: Date())
            await MainActor.run { [weak self] in
                self?.apply(sorted)
            }
        }
    }

    private func apply(_ sorted: [ClaudeSession]) {
        sessions = sorted
        let count = sorted.count
        let waitingNow = ClaudeSessions.waitingCount(sorted)
        guard count != lastLoggedCount || waitingNow != lastLoggedWaiting else { return }
        lastLoggedCount = count
        lastLoggedWaiting = waitingNow
        logger.notice("claudeSessions count=\(count, privacy: .public) waiting=\(waitingNow, privacy: .public)")
    }

    /// Off the main actor: lists `directoryURL` (a missing directory degrades to an empty list,
    /// not an error), keeps only regular, non-symlinked `.json` files at or under
    /// `ClaudeSessionDecoder.maxBytes` (checked via resource values BEFORE the file is read),
    /// decodes each through `ClaudeSessionDecoder`, drops sessions whose owning process is gone,
    /// and sorts via `ClaudeSessions.sorted`. Read-only end to end — no write/rename/delete call
    /// of any kind touches `directoryURL` (T-07-22's own acceptance grep).
    nonisolated private static func readAndSort(directoryURL: URL, now: Date) -> [ClaudeSession] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var decoded: [ClaudeSession] = []
        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            if let size = values.fileSize, size > ClaudeSessionDecoder.maxBytes { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let session = ClaudeSessionDecoder.decode(data: data, fileName: url.lastPathComponent, now: now) else { continue }
            guard isLive(session, now: now) else { continue }
            decoded.append(session)
        }
        return ClaudeSessions.sorted(decoded)
    }

    /// `kill(pid, 0)` is the standard liveness probe (sends no signal, just checks the pid
    /// exists and is reachable) — a missing pid can't be liveness-checked at all, so it's kept
    /// rather than hidden; a non-`ESRCH` error (e.g. `EPERM`, a pid owned by a different user)
    /// is treated as "can't tell, presume alive" for the same reason. A dead pid (`ESRCH`) is
    /// dropped UNLESS the session still `needsYou` and its file is under 60s old — the grace
    /// window between the owning `claude` process exiting and `SessionEnd` removing the file.
    nonisolated private static func isLive(_ session: ClaudeSession, now: Date) -> Bool {
        guard let pid = session.pid else { return true }
        if kill(pid, 0) == 0 { return true }
        guard errno == ESRCH else { return true }
        if session.status.needsYou, now.timeIntervalSince(session.updatedAt) < 60 { return true }
        return false
    }

    deinit {
        pollTimer?.invalidate()
    }
}
