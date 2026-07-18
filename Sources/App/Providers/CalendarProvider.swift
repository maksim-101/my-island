import EventKit
import AppKit
import SwiftUI
import OSLog
import MyIslandCore

/// Calendar access (CAL-01, D-03): a long-lived actor-isolated `EKEventStore`
/// plus a `@MainActor` provider that mirrors its authorization state for the
/// panel. Per RESEARCH.md Pattern 1: never let `EKEvent`/`EKEventStore` cross
/// the actor boundary — only the `Sendable` `CalendarEventModel` projection
/// does. `CalendarProvider.requestOrOpenSettings()` gates strictly on the
/// current authorization status and never re-calls the request API once
/// denied/restricted (Pitfall 2) — it routes to System Settings instead.
actor CalendarService {
    /// ONE instance, created ONCE — recreating `EKEventStore` per fetch is
    /// expensive (DB connection, schema read, daemon handshake).
    private let eventStore = EKEventStore()

    /// Requests full Calendar access, but only when status is
    /// `.notDetermined`. Calling `requestFullAccessToEvents()` again after a
    /// denial returns `false` immediately with no OS prompt (Pitfall 2) — the
    /// caller must check status first and route denied/restricted elsewhere.
    ///
    /// DIAGNOSTIC INSTRUMENTATION (round 3, checkpoint still failing after the
    /// round-2 `.regular`-activation fallback): brackets the actual
    /// `requestFullAccessToEvents()` call with NSLog so a `log stream` capture
    /// shows whether this actor method is even reached, what status it read
    /// at entry, and what the completion result/error was.
    func requestAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        NSLog("[CalendarService] requestAccess() entry, authorizationStatus=%@", String(describing: status))
        switch status {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            NSLog("[CalendarService] status is .notDetermined — invoking requestFullAccessToEvents()")
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                NSLog("[CalendarService] requestFullAccessToEvents() completed: granted=%@", String(granted))
                return granted
            } catch {
                NSLog("[CalendarService] requestFullAccessToEvents() threw: %@", String(describing: error))
                return false
            }
        case .denied, .restricted, .writeOnly:
            NSLog("[CalendarService] status is denied/restricted/writeOnly — NOT re-requesting (Pitfall 2)")
            return false
        @unknown default:
            return false
        }
    }

    /// Reads the current authorization status. Safe to call off the actor —
    /// `EKEventStore.authorizationStatus(for:)` is a class method that reads
    /// system state, not the actor-isolated `eventStore` instance.
    nonisolated func currentStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }
}

/// Sendable projection of an `EKEvent` — never the live EventKit type itself
/// (Pitfall 1). Populated by plan 04-03; this plan only declares the shape.
struct CalendarEventModel: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let joinURL: URL?
}

@MainActor
@Observable
final class CalendarProvider {
    enum AuthorizationState {
        case notDetermined
        case denied
        case restricted
        case granted
    }

    private(set) var authorizationState: AuthorizationState
    /// nil until plan 04-03 wires real fetches.
    private(set) var nextEvent: CalendarEventModel?

    private let service = CalendarService()
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "CalendarProvider")

    init() {
        authorizationState = Self.map(status: EKEventStore.authorizationStatus(for: .event))
    }

    private static func map(status: EKAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .fullAccess, .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .writeOnly:
            return .denied
        @unknown default:
            return .denied
        }
    }

    private func refreshAuthState() {
        authorizationState = Self.map(status: service.currentStatus())
    }

    /// Requests access when not yet determined; otherwise routes to System
    /// Settings — NEVER re-calls `requestFullAccessToEvents()` once
    /// denied/restricted (Pitfall 2, T-04-05).
    ///
    /// Checkpoint result (real Tahoe hardware, plan 04-02 Task 3, round 1):
    /// clicking Grant Access from the shipped non-activating `NSPanel`
    /// produced NO dialog and no visible reaction whatsoever — confirming
    /// Assumption A4 is FALSE (Open Question 1).
    ///
    /// Round 2 fix (`.regular`-activation, calling `requestAccess()`
    /// synchronously in the very next line after `activate()`) ALSO produced
    /// no dialog. Leading theory going into round 3: `setActivationPolicy`/
    /// `activate(ignoringOtherApps:)` do not synchronously bring the app
    /// frontmost before the next line runs — TCC may still see a
    /// non-foreground requester at the moment `requestFullAccessToEvents()`
    /// actually fires. Round 3 fix: wait for an actual foreground
    /// confirmation (`NSApplication.didBecomeActiveNotification`) before
    /// invoking the request, with a 0.3s fallback timer in case the
    /// notification doesn't fire (e.g. the app was already active).
    func requestOrOpenSettings() {
        NSLog(
            "[CalendarProvider] requestOrOpenSettings() invoked, authorizationState=%@, activationPolicy(before)=%@, isActive(before)=%@",
            String(describing: authorizationState),
            String(describing: NSApp.activationPolicy()),
            String(NSApp.isActive)
        )
        switch authorizationState {
        case .notDetermined:
            activateThenRequest()
        case .denied, .restricted:
            openSystemSettings()
        case .granted:
            break
        }
    }

    /// Promotes to `.regular` + activates, then waits for an actual
    /// foreground-confirmation signal (not just the next run-loop tick)
    /// before invoking the privacy-gated request — see round 3 rationale
    /// above `requestOrOpenSettings()`.
    private func activateThenRequest() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSLog(
            "[CalendarProvider] set .regular + activate() called, activationPolicy(immediately after)=%@, isActive(immediately after)=%@",
            String(describing: NSApp.activationPolicy()),
            String(NSApp.isActive)
        )

        var didFire = false
        var observer: NSObjectProtocol?
        let fireOnce: (String) -> Void = { [weak self] source in
            guard !didFire else { return }
            didFire = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            NSLog(
                "[CalendarProvider] foreground-confirmation source=%@, isActive(at fire)=%@ — invoking request",
                source, String(NSApp.isActive)
            )
            self?.performRequest()
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            fireOnce("didBecomeActiveNotification")
        }

        // Safety net: if the app was already active (no notification will
        // fire) or the notification is otherwise missed, still proceed after
        // one run-loop cycle's worth of settle time rather than hanging
        // forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            fireOnce("fallback-timeout-0.3s")
        }
    }

    private func performRequest() {
        NSLog(
            "[CalendarProvider] about to call requestAccess(), activationPolicy=%@, isActive=%@",
            String(describing: NSApp.activationPolicy()),
            String(NSApp.isActive)
        )
        Task {
            let granted = await service.requestAccess()
            NSLog("[CalendarProvider] requestAccess() returned granted=%@", String(granted))
            refreshAuthState()
            NSApp.setActivationPolicy(.accessory)
            NSLog("[CalendarProvider] reverted activationPolicy to .accessory")
        }
    }

    /// Opens the Calendars privacy pane. Prefers the modern System Settings
    /// deep-link (Ventura+); falls back to the older System Preferences form
    /// if the modern one fails to open (Pitfall 5). Logs only the open
    /// failure/fallback — never event data (T-04-06).
    private func openSystemSettings() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")
        if let modern, NSWorkspace.shared.open(modern) {
            return
        }
        logger.info("Modern System Settings deep-link failed to open — falling back to legacy form")
        if let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            if !NSWorkspace.shared.open(legacy) {
                logger.error("Legacy System Settings deep-link also failed to open")
            }
        }
    }
}
