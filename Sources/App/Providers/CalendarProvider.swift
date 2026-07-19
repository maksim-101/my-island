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
    /// DIAGNOSTIC INSTRUMENTATION (round 6 — file-based, see `DebugLog`):
    /// round 5's real-hardware capture (Apple's own un-redacted EventKit
    /// system log, not ours) proved this method IS reached, DOES read
    /// `.notDetermined`, and DOES call the real `requestFullAccessToEvents()`
    /// — but TCC returned a synchronous NO in ~4ms, too fast for a
    /// human-seen dialog. That pointed at the caller's activation context,
    /// not this method, so the round 6 fix lives in `CalendarProvider`.
    func requestAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        DebugLog.write("[CalendarService] requestAccess() entry, authorizationStatus=\(status)")
        switch status {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            DebugLog.write("[CalendarService] status is .notDetermined — invoking requestFullAccessToEvents()")
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                DebugLog.write("[CalendarService] requestFullAccessToEvents() completed: granted=\(granted)")
                return granted
            } catch {
                DebugLog.write("[CalendarService] requestFullAccessToEvents() threw: \(error)")
                return false
            }
        case .denied, .restricted, .writeOnly:
            DebugLog.write("[CalendarService] status is denied/restricted/writeOnly — NOT re-requesting (Pitfall 2)")
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

    /// Round 6: the temporary real `NSWindow` created solely so TCC has an
    /// actual key window to anchor the permission sheet to. Held for the
    /// duration of a single request, then closed and released.
    private var accessRequestWindow: NSWindow?

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
    /// History (real Tahoe hardware, plan 04-02 Task 3 checkpoint):
    /// - Round 1: no dialog, no reaction at all from the shipped
    ///   non-activating `NSPanel` — confirmed Assumption A4 is FALSE.
    /// - Round 2: `.regular`-activation, calling `requestAccess()`
    ///   synchronously right after `activate()` — still no dialog.
    /// - Round 3: waited for `didBecomeActiveNotification` before
    ///   requesting (with a 0.3s fallback) — still no dialog.
    /// - Round 4/5: click probes proved the click DOES reach the Button
    ///   (round 5's un-redacted EventKit system log showed
    ///   `requestFullAccessToEvents()` IS invoked and TCC returns a
    ///   synchronous NO in ~4ms — far too fast for a human-seen dialog).
    /// - Round 6 theory: TCC's eligibility check for showing a permission
    ///   sheet requires an actual KEY window, not just `NSApp.isActive`/
    ///   `.regular` policy — every window this app owns is a
    ///   non-main-capable `NSPanel` (`canBecomeMain == false`), so
    ///   `activate()` alone never produces one. Fix: create a minimal real
    ///   `NSWindow`, make it key, wait for actual key-window confirmation,
    ///   THEN fire the request.
    func requestOrOpenSettings() {
        DebugLog.write(
            "[CalendarProvider] requestOrOpenSettings() invoked, authorizationState=\(authorizationState), activationPolicy(before)=\(NSApp.activationPolicy()), isActive(before)=\(NSApp.isActive)"
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

    /// Promotes to `.regular` + activates, creates a minimal real `NSWindow`
    /// and makes it key (round 6 fix — see rationale above
    /// `requestOrOpenSettings()`), then waits for actual key-window
    /// confirmation before invoking the privacy-gated request.
    private func activateThenRequest() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.write(
            "[CalendarProvider] set .regular + activate() called, activationPolicy(immediately after)=\(NSApp.activationPolicy()), isActive(immediately after)=\(NSApp.isActive)"
        )

        // A genuine NSWindow (NOT an NSPanel with .nonactivatingPanel) so it
        // CAN become key/main — every window this app otherwise owns is a
        // non-main-capable NSPanel (see NotchPanel.canBecomeMain == false).
        //
        // Round 6 attempt used `styleMask: [.borderless]` and never actually
        // became key (`isKeyWindow` stayed false a full 0.3s later, so only
        // the fallback timer fired) — a borderless window's `canBecomeKey`
        // returns false by default; it needs an explicit override OR a style
        // mask AppKit already treats as key-capable. Round 7: match this
        // codebase's own PROVEN-working precedent exactly —
        // `AppDelegate.showSettings()`'s window uses `styleMask: [.titled,
        // .closable]`, which is key-capable with no subclass/override
        // needed. A small-but-real, briefly visible window is acceptable
        // for this one-time permission grant (per round-6 guidance) — this
        // is not trying to be invisible anymore, it needs to actually work.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "my-island"
        window.isReleasedWhenClosed = false
        window.center()
        accessRequestWindow = window

        var didFire = false
        var observer: NSObjectProtocol?
        let fireOnce: (String) -> Void = { [weak self] source in
            guard !didFire else { return }
            didFire = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            DebugLog.write(
                "[CalendarProvider] key-window-confirmation source=\(source), isKeyWindow=\(window.isKeyWindow), isActive=\(NSApp.isActive) — invoking request"
            )
            self?.performRequest()
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            fireOnce("didBecomeKeyNotification")
        }

        window.makeKeyAndOrderFront(nil)
        DebugLog.write("[CalendarProvider] created + ordered minimal key window, isKeyWindow(immediately)=\(window.isKeyWindow)")

        // Safety net: proceed even if the notification is missed for some
        // reason, rather than hanging forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            fireOnce("fallback-timeout-0.3s")
        }
    }

    private func performRequest() {
        DebugLog.write(
            "[CalendarProvider] about to call requestAccess(), activationPolicy=\(NSApp.activationPolicy()), isActive=\(NSApp.isActive), isKeyWindow=\(accessRequestWindow?.isKeyWindow ?? false)"
        )
        Task {
            let granted = await service.requestAccess()
            DebugLog.write("[CalendarProvider] requestAccess() returned granted=\(granted)")
            refreshAuthState()
            accessRequestWindow?.close()
            accessRequestWindow = nil
            NSApp.setActivationPolicy(.accessory)
            DebugLog.write("[CalendarProvider] closed temp window + reverted activationPolicy to .accessory")
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
