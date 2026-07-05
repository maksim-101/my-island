import AppKit
import OSLog
import MyIslandCore

/// `@MainActor`-isolated recent-clipboard history (CLIP-01, CLIP-02). Polls
/// `NSPasteboard.general.changeCount` on a 0.5s `Timer` (no push notification
/// exists for pasteboard changes) and filters every candidate through
/// `ClipboardSensitivity.isSensitive(declaredTypes:)` BEFORE the string is
/// ever read/stored (D-15) — not a display-time redaction. History is
/// in-memory only for the process lifetime; nothing is written to disk
/// (D-14).
@MainActor
@Observable
final class ClipboardViewModel {
    struct ClipboardEntry: Identifiable {
        let id = UUID()
        let text: String
        let copiedAt: Date
    }

    private(set) var entries: [ClipboardEntry] = []   // newest first, max 10 (D-13)
    private var lastChangeCount: Int
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "ClipboardViewModel")

    // Accessed from `deinit`, which runs nonisolated — safe because
    // `Timer.invalidate()` is thread-agnostic and no other isolated state is
    // touched there (mirrors `TimerViewModel.tickTimer`).
    nonisolated(unsafe) private var pollTimer: Timer?

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollIfChanged() }
        }
    }

    private func pollIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let item = pasteboard.pasteboardItems?.first else { return }
        let declaredTypes = item.types.map(\.rawValue)
        guard !ClipboardSensitivity.isSensitive(declaredTypes: declaredTypes) else { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        // Avoid duplicate consecutive entries (re-copying the same text, or
        // our own re-copy-on-select from CLIP-02 triggering a false "new"
        // entry).
        guard entries.first?.text != text else { return }

        entries.insert(ClipboardEntry(text: text, copiedAt: .now), at: 0)
        if entries.count > 10 { entries.removeLast(entries.count - 10) }   // D-13
        logger.debug("Recorded clipboard entry")
    }

    /// CLIP-02: re-copy a history entry to the system clipboard without it
    /// being re-recorded as a new entry (Pitfall 3).
    func select(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        // Written synchronously right after setString so the next poll sees
        // no delta.
        lastChangeCount = pasteboard.changeCount
    }

    deinit {
        pollTimer?.invalidate()
    }
}
