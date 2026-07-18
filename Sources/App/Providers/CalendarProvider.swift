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
    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            return (try? await eventStore.requestFullAccessToEvents()) ?? false
        case .denied, .restricted, .writeOnly:
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
    /// Checkpoint result (real Tahoe hardware, plan 04-02 Task 3): clicking
    /// Grant Access from the shipped non-activating `NSPanel` produced NO
    /// dialog and no visible reaction whatsoever — confirming Assumption A4
    /// is FALSE (Open Question 1). The first request is therefore routed
    /// through the same `.regular`-activation trick `AppDelegate.showSettings`
    /// already uses for the KeyboardShortcuts conflict-alert modal (the
    /// Dicticus pattern, Pitfall 3): briefly promote to `.regular` + activate
    /// so the OS has an actual foreground app to anchor the TCC sheet to,
    /// then revert to `.accessory` (this app's `LSUIElement` default) once
    /// the request completes, so no Dock icon is left behind.
    func requestOrOpenSettings() {
        switch authorizationState {
        case .notDetermined:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            Task {
                _ = await service.requestAccess()
                refreshAuthState()
                NSApp.setActivationPolicy(.accessory)
            }
        case .denied, .restricted:
            openSystemSettings()
        case .granted:
            break
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
