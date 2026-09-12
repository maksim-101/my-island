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
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                return granted
            } catch {
                return false
            }
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

    /// Progressive date-window widths (RESEARCH.md Pattern 1) — searched in
    /// order, starting from `now`, widening only when a window surfaces no
    /// eligible event.
    private static let progressiveWindows: [TimeInterval] = [
        24 * 3600,
        7 * 24 * 3600,
        30 * 24 * 3600,
        90 * 24 * 3600,
        365 * 24 * 3600,
    ]

    /// Fetches the soonest surfaced event across a progressively widening
    /// date window (Pattern 1). `selectedCalendarIDs` is `nil` before Task 3
    /// wires per-calendar selection (or if the persisted set is somehow
    /// empty/corrupt) — a `nil` value resolves to `nil` calendars, which
    /// `predicateForEvents(withStart:end:calendars:)` treats as "search all
    /// calendars," never an empty/broken query. Never returns an `EKEvent` —
    /// only the `Sendable` `CalendarEventModel` projection crosses the actor
    /// boundary (Pitfall 1).
    /// Returns the event currently in progress (if any) followed by the next
    /// one that hasn't started yet (if any) — at most two. Returning both is
    /// what lets a running meeting keep its Join button WITHOUT starving the
    /// meeting behind it of its threshold bumps; `CalendarSlotSelector` decides
    /// which of them the panel actually renders.
    func fetchUpcomingSlots(now: Date = .now, selectedCalendarIDs: Set<String>? = nil) async -> [CalendarEventModel] {
        guard await requestAccess() else { return [] }

        let calendars: [EKCalendar]? = selectedCalendarIDs.map { ids in
            eventStore.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        }

        for window in Self.progressiveWindows {
            let end = now.addingTimeInterval(window)
            let predicate = eventStore.predicateForEvents(withStart: now, end: end, calendars: calendars)
            let surfaced = eventStore.events(matching: predicate)
                .filter { event in
                    let attendance = CalendarEventFilter.resolvedAttendance(
                        isOrganizer: event.organizer?.isCurrentUser ?? false,
                        hasAttendees: event.hasAttendees,
                        currentUserStatus: Self.mapParticipantStatus(
                            event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus
                        )
                    )
                    return CalendarEventFilter.shouldSurface(
                        isCancelled: event.status == .canceled,
                        isAllDay: event.isAllDay,
                        attendance: attendance
                    )
                }
                .sorted { $0.startDate < $1.startDate }

            guard !surfaced.isEmpty else { continue }

            // The two earliest cover whatever the panel can render; the first
            // not-yet-started event is appended when it isn't already among
            // them, so thresholds can still arm while two meetings run at once.
            var picked = Array(surfaced.prefix(2))
            if let upcoming = surfaced.first(where: { $0.startDate > now }),
               !picked.contains(where: { $0 === upcoming }) {
                picked.append(upcoming)
            }
            return picked.map(mapToSendable)
        }
        return []
    }

    /// Reads all calendars across all accounts, grouped by their `EKSource`,
    /// as plain `String` id/title tuples — never an `EKCalendar`/`EKSource`
    /// crosses the actor boundary (Pitfall 1 extended to the Settings
    /// per-calendar picker). Touches the actor-isolated `eventStore`, so this
    /// stays an ordinary actor-isolated method (an EventKit read cannot be
    /// `nonisolated`) — callers `await` it like any other `CalendarService`
    /// method.
    func calendarsGroupedBySource() -> [(sourceName: String, calendars: [(id: String, title: String)])] {
        let grouped = Dictionary(grouping: eventStore.calendars(for: .event)) { $0.source.sourceIdentifier }
        return grouped.values
            .compactMap { group -> (sourceName: String, calendars: [(id: String, title: String)])? in
                guard let sourceName = group.first?.source.title else { return nil }
                let calendarTuples = group
                    .sorted { $0.title < $1.title }
                    .map { (id: $0.calendarIdentifier, title: $0.title) }
                return (sourceName: sourceName, calendars: calendarTuples)
            }
            .sorted { $0.sourceName < $1.sourceName }
    }

    /// Adapts an `EKEvent` into the `Sendable` projection — NEVER returns the
    /// live `EKEvent` itself (Pitfall 1). Calls `VideoLinkDetector.detect` at
    /// this actor boundary so no EventKit type crosses into `CalendarProvider`.
    private func mapToSendable(_ event: EKEvent) -> CalendarEventModel {
        let startDate = event.startDate ?? .now
        let joinURL = VideoLinkDetector.detect(url: event.url?.absoluteString, location: event.location, notes: event.notes)
        return CalendarEventModel(
            id: "\(event.eventIdentifier ?? "")_\(startDate.timeIntervalSince1970)",
            title: event.title ?? "",
            startDate: startDate,
            endDate: event.endDate ?? startDate,
            location: event.location,
            joinURL: joinURL
        )
    }

    /// Adapts `EKParticipantStatus` onto the pure `CalendarEventFilter`
    /// input type so no EventKit type crosses the actor boundary.
    private static func mapParticipantStatus(_ status: EKParticipantStatus?) -> CalendarEventFilter.AttendanceStatus? {
        guard let status else { return nil }
        switch status {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        default: return .other
        }
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
    /// In-progress event (if any) + the next not-yet-started one (if any).
    /// Both are kept even when only one is rendered, so thresholds can arm for
    /// the upcoming meeting while a long one is still running.
    private(set) var events: [CalendarEventModel] = []
    /// What the panel renders: one row normally, two only while a running
    /// meeting genuinely overlaps the next one.
    private(set) var displayedEvents: [CalendarEventModel] = []
    /// Live short-form ("{N}m" / "now") countdown per event id, recomputed every
    /// second by `tickTimer` from the cached `events` only — never by
    /// re-querying EventKit (Pattern 4, Pitfall 7).
    private(set) var countdowns: [String: String] = [:]

    /// Fired exactly once per 15m/5m/1m threshold per event (Pattern 3) with a
    /// "{title} in {N}m" string — `NotchPanelController` wires this into
    /// `hud.showMeeting(text:)`, the same idiom as `volumeProvider.onChange`/
    /// `brightnessProvider.onChange`.
    var onThresholdCrossed: ((String) -> Void)?

    private let service = CalendarService()
    private let logger = AppLog.make("CalendarProvider")

    /// Round 6: the temporary real `NSWindow` created solely so TCC has an
    /// actual key window to anchor the permission sheet to. Held for the
    /// duration of a single request, then closed and released.
    private var accessRequestWindow: NSWindow?

    // Cheap 1s tick: recomputes `countdownText` from the cached `nextEvent`
    // only. Started when `nextEvent != nil`, stopped when `nil` (Pattern 4).
    // Accessed from `deinit`, which runs nonisolated — safe because
    // `Timer.invalidate()` is thread-agnostic (mirrors `TimerViewModel`).
    nonisolated(unsafe) private var tickTimer: Timer?
    // Coarse fallback re-fetch (~20 min) in case neither
    // `EKEventStoreChanged` nor `NSCalendarDayChanged` fires while an event's
    // window is open (mirrors `BrightnessProvider.pollTimer`).
    nonisolated(unsafe) private var fallbackTimer: Timer?
    nonisolated(unsafe) private var eventStoreChangedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var dayChangedObserver: NSObjectProtocol?

    // Single soonest-fire-date timer (re-armed after every fire), plus the
    // per-event fired-threshold tracking (Pattern 3) — scoped to
    // `firedThresholdsEventID` so a no-op `EKEventStoreChanged` (nextEvent
    // unchanged) never re-fires a threshold already shown for this event.
    nonisolated(unsafe) private var thresholdTimer: Timer?
    private var firedThresholdsEventID: String?
    private var firedThresholds: Set<Date> = []

    init() {
        authorizationState = Self.map(status: EKEventStore.authorizationStatus(for: .event))

        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNextEvent() }
        }
        dayChangedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNextEvent() }
        }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNextEvent() }
        }

        if authorizationState == .granted {
            refreshNextEvent()
        }
    }

    deinit {
        tickTimer?.invalidate()
        fallbackTimer?.invalidate()
        thresholdTimer?.invalidate()
        if let eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(eventStoreChangedObserver)
        }
        if let dayChangedObserver {
            NotificationCenter.default.removeObserver(dayChangedObserver)
        }
    }

    /// Heavy fetch: re-queries EventKit via the actor and republishes
    /// `events` + `countdowns` on the main actor. Call on init (when
    /// granted), on `EKEventStoreChanged`, on `.NSCalendarDayChanged`, and
    /// from the coarse fallback timer above — never from the cheap 1s tick.
    func refreshNextEvent() {
        guard authorizationState == .granted else {
            events = []
            computeCountdowns()
            rescheduleThresholds()
            return
        }
        Task {
            let ids = self.selectedCalendarIDs
            let fetched = await service.fetchUpcomingSlots(selectedCalendarIDs: ids)
            self.events = fetched
            self.computeCountdowns()
            self.rescheduleThresholds()
        }
    }

    // MARK: - 15m/5m/1m threshold-bump scheduling (Pattern 3)

    /// Invalidates any pending threshold timer and re-derives the pending fire
    /// dates from the current `nextEvent` via `ThresholdScheduler.pendingFireDates`
    /// — called whenever `nextEvent` changes (event rescheduled, cancelled, a
    /// closer event appears, or auth revoked). Clears the fired-threshold set
    /// only when the event's identity actually changes, so a no-op
    /// `EKEventStoreChanged` never re-fires an already-shown threshold.
    private func rescheduleThresholds() {
        thresholdTimer?.invalidate()
        thresholdTimer = nil

        // The event that hasn't started yet — NOT `events.first`, which is the
        // in-progress one whenever a meeting is running. Arming off the running
        // meeting is what silently starved the next one of its bumps.
        guard let event = events.first(where: { $0.startDate > .now }) else {
            firedThresholdsEventID = nil
            firedThresholds = []
            return
        }

        if firedThresholdsEventID != event.id {
            firedThresholdsEventID = event.id
            firedThresholds = []
        }

        armNextThreshold(for: event)
    }

    /// Arms a one-shot timer for the soonest not-yet-fired threshold, or does
    /// nothing if every threshold for this event has already fired/passed.
    private func armNextThreshold(for event: CalendarEventModel) {
        let pending = ThresholdScheduler.pendingFireDates(eventStart: event.startDate, now: .now)
            .filter { !firedThresholds.contains($0) }
        guard let next = pending.first else { return }

        let interval = max(0, next.timeIntervalSinceNow)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireThreshold(fireDate: next, event: event) }
        }
        // Absolute fire date + .common mode: a `scheduledTimer` interval timer in
        // .default mode is silently starved while the run loop sits in event
        // tracking (hover/menu), and an idle agent app's timers get coalesced by
        // App Nap — both would drop a bump on the floor.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        thresholdTimer = timer
    }

    /// Records the fired date, invokes `onThresholdCrossed` with the
    /// "{title} in {N}m" text (title truncation is HUDPillView's job via
    /// `.lineLimit(1)`), then arms the next pending threshold for the same
    /// event. Guards against a stale timer firing after `nextEvent` has
    /// already moved on to a different event.
    private func fireThreshold(fireDate: Date, event: CalendarEventModel) {
        guard events.contains(where: { $0.id == event.id }) else {
            return
        }
        firedThresholds.insert(fireDate)
        let unit = RelativeTimeFormat.string(remaining: event.startDate.timeIntervalSince(fireDate), rounding: .nearest)
        onThresholdCrossed?("\(event.title) in \(unit)")
        armNextThreshold(for: event)
    }

    // MARK: - Per-calendar selection (Task 3)

    private static let selectedCalendarIDsKey = "com.myisland.selectedCalendarIDs"

    /// `nil` when the key has never been set (first-ever run) — resolves to
    /// "all calendars" both here and in `CalendarService.fetchNextUpcomingEvent`,
    /// so an existing granted user's next-meeting keeps working exactly as
    /// before this feature until they actually open Settings and deselect
    /// something (opt-out, not opt-in).
    private var selectedCalendarIDs: Set<String>? {
        get {
            guard let ids = UserDefaults.standard.array(forKey: Self.selectedCalendarIDsKey) as? [String] else {
                return nil
            }
            return Set(ids)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Array(newValue), forKey: Self.selectedCalendarIDsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedCalendarIDsKey)
            }
        }
    }

    /// `true` when no selection has ever been persisted (opt-out default —
    /// every calendar counts until the user actually touches a toggle).
    func isCalendarSelected(_ id: String) -> Bool {
        guard let selectedCalendarIDs else { return true }
        return selectedCalendarIDs.contains(id)
    }

    /// Mutates the persisted selection and immediately triggers a
    /// `refreshNextEvent()` so the toggle takes effect without an app
    /// restart. On the FIRST toggle touch (no persisted set yet), the
    /// current "all calendars" set is materialized first so calendars the
    /// user hasn't yet seen aren't silently dropped by a partial selection.
    func setCalendarSelected(_ id: String, selected: Bool) async {
        var current: Set<String>
        if let existing = selectedCalendarIDs {
            current = existing
        } else {
            let allIDs = await service.calendarsGroupedBySource().flatMap { $0.calendars.map(\.id) }
            current = Set(allIDs)
        }
        if selected {
            current.insert(id)
        } else {
            current.remove(id)
        }
        selectedCalendarIDs = current
        refreshNextEvent()
    }

    /// Delegates the actual `EKEventStore.calendars(for:)` read to the actor
    /// — returns plain `String` id/title tuples only, never an
    /// `EKCalendar`/`EKSource` (Pitfall 1 extended to the Settings picker).
    func availableCalendarsGroupedBySource() async -> [(sourceName: String, calendars: [(id: String, title: String)])] {
        await service.calendarsGroupedBySource()
    }

    /// Recomputes every cached event's countdown from its `startDate` only — no
    /// EventKit call (Pitfall 7). Clamps at/near T-0 to a neutral "now" label
    /// rather than ever rendering a negative value, and drops an event once its
    /// `endDate` passes (backstop truth). Also re-derives `displayedEvents`, so
    /// the second row appears/disappears as a meeting starts or ends without
    /// waiting on a heavy re-fetch.
    private func computeCountdowns(now: Date = .now) {
        let stillLive = events.filter { now < $0.endDate }
        let dropped = stillLive.count != events.count
        events = stillLive

        guard !events.isEmpty else {
            displayedEvents = []
            countdowns = [:]
            stopTick()
            if dropped { refreshNextEvent() }
            return
        }

        countdowns = Dictionary(uniqueKeysWithValues: events.map { event in
            let remaining = event.startDate.timeIntervalSince(now)
            return (event.id, RelativeTimeFormat.string(remaining: remaining, rounding: .floor))
        })

        let selection = CalendarSlotSelector.select(
            slots: events.map { EventSlot(start: $0.startDate, end: $0.endDate) },
            now: now
        )
        displayedEvents = [selection.primary, selection.secondary]
            .compactMap { $0 }
            .map { events[$0] }

        startTickIfNeeded()
        // A finished event frees its slot — re-query so the one behind it
        // (and its threshold bumps) takes over immediately.
        if dropped { refreshNextEvent() }
    }

    private func startTickIfNeeded() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.computeCountdowns() }
        }
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
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

        // Safety net: proceed even if the notification is missed for some
        // reason, rather than hanging forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            fireOnce("fallback-timeout-0.3s")
        }
    }

    private func performRequest() {
        Task {
            let granted = await service.requestAccess()
            refreshAuthState()
            if authorizationState == .granted {
                refreshNextEvent()
            }
            accessRequestWindow?.close()
            accessRequestWindow = nil
            NSApp.setActivationPolicy(.accessory)
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
