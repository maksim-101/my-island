import Testing
import Foundation
@testable import MyIslandCore

@Test func resolvedAttendanceIsAcceptedWhenOrganizer() {
    let result = CalendarEventFilter.resolvedAttendance(isOrganizer: true, hasAttendees: true, currentUserStatus: .declined)
    #expect(result == .accepted)
}

@Test func resolvedAttendanceUsesExplicitCurrentUserStatus() {
    let result = CalendarEventFilter.resolvedAttendance(isOrganizer: false, hasAttendees: true, currentUserStatus: .declined)
    #expect(result == .declined)
}

@Test func resolvedAttendanceIsAcceptedForPersonalSoloEvent() {
    let result = CalendarEventFilter.resolvedAttendance(isOrganizer: false, hasAttendees: false, currentUserStatus: nil)
    #expect(result == .accepted)
}

@Test func shouldSurfaceIsFalseWhenCancelled() {
    let result = CalendarEventFilter.shouldSurface(isCancelled: true, isAllDay: false, attendance: .accepted)
    #expect(!result)
}

@Test func shouldSurfaceIsFalseForAllDayEvents() {
    let result = CalendarEventFilter.shouldSurface(isCancelled: false, isAllDay: true, attendance: .accepted)
    #expect(!result)
}

@Test func shouldSurfaceIsFalseWhenDeclined() {
    let result = CalendarEventFilter.shouldSurface(isCancelled: false, isAllDay: false, attendance: .declined)
    #expect(!result)
}

@Test func shouldSurfaceIsFalseWhenTentative() {
    let result = CalendarEventFilter.shouldSurface(isCancelled: false, isAllDay: false, attendance: .tentative)
    #expect(!result)
}

@Test func shouldSurfaceIsTrueForAcceptedNonAllDayNonCancelledEvent() {
    let result = CalendarEventFilter.shouldSurface(isCancelled: false, isAllDay: false, attendance: .accepted)
    #expect(result)
}

@Test func pendingFireDatesSkipsAlreadyPastThresholdFor14MinutesOut() {
    let now = Date(timeIntervalSince1970: 0)
    let eventStart = now.addingTimeInterval(14 * 60)
    let result = ThresholdScheduler.pendingFireDates(eventStart: eventStart, now: now)
    let expected = [eventStart.addingTimeInterval(-5 * 60), eventStart.addingTimeInterval(-60)]
    #expect(result == expected)
}

@Test func pendingFireDatesReturnsAllThreeFor20MinutesOut() {
    let now = Date(timeIntervalSince1970: 0)
    let eventStart = now.addingTimeInterval(20 * 60)
    let result = ThresholdScheduler.pendingFireDates(eventStart: eventStart, now: now)
    let expected = [
        eventStart.addingTimeInterval(-15 * 60),
        eventStart.addingTimeInterval(-5 * 60),
        eventStart.addingTimeInterval(-60),
    ]
    #expect(result == expected)
}

// MARK: - CalendarSlotSelector (overlapping meetings)

/// The 06:00–07:00 / 06:15 case from real-hardware UAT: the running meeting
/// must not hide the one starting behind it.
@Test func isWithinBumpWindowTrueJustInsideFifteenMinutes() {
    #expect(ThresholdScheduler.isWithinBumpWindow(remaining: 899))
}

@Test func isWithinBumpWindowTrueAtExactlyFifteenMinutes() {
    #expect(ThresholdScheduler.isWithinBumpWindow(remaining: 900))
}

@Test func isWithinBumpWindowFalseJustOutsideFifteenMinutes() {
    #expect(!ThresholdScheduler.isWithinBumpWindow(remaining: 901))
}

@Test func isWithinBumpWindowTrueForAlreadyStartedEvent() {
    #expect(ThresholdScheduler.isWithinBumpWindow(remaining: -30))
}

@Test func selectSurfacesBothWhenUpcomingStartsBeforeRunningEnds() {
    let now = Date(timeIntervalSince1970: 0)
    let slots = [
        EventSlot(start: now.addingTimeInterval(-4 * 60), end: now.addingTimeInterval(56 * 60)),
        EventSlot(start: now.addingTimeInterval(11 * 60), end: now.addingTimeInterval(41 * 60)),
    ]
    let result = CalendarSlotSelector.select(slots: slots, now: now)
    #expect(result.primary == 0)
    #expect(result.secondary == 1)
}

/// Two meetings running AT THE SAME TIME — the case an in-progress/upcoming
/// split dropped, because neither of them is "upcoming".
@Test func selectSurfacesBothWhenTwoMeetingsRunConcurrently() {
    let now = Date(timeIntervalSince1970: 0)
    let slots = [
        EventSlot(start: now.addingTimeInterval(-28 * 60), end: now.addingTimeInterval(32 * 60)),
        EventSlot(start: now.addingTimeInterval(-8 * 60), end: now.addingTimeInterval(17 * 60)),
    ]
    let result = CalendarSlotSelector.select(slots: slots, now: now)
    #expect(result.primary == 0)
    #expect(result.secondary == 1)
}

@Test func selectDoesNotTreatLaterNonOverlappingEventAsOverlap() {
    let now = Date(timeIntervalSince1970: 0)
    let slots = [
        EventSlot(start: now.addingTimeInterval(-5 * 60), end: now.addingTimeInterval(25 * 60)),
        EventSlot(start: now.addingTimeInterval(24 * 3600), end: now.addingTimeInterval(25 * 3600)),
    ]
    let result = CalendarSlotSelector.select(slots: slots, now: now)
    #expect(result.primary == 0)
    #expect(result.secondary == nil)
}

@Test func selectReturnsOnlyUpcomingWhenNothingRunning() {
    let now = Date(timeIntervalSince1970: 0)
    let slots = [EventSlot(start: now.addingTimeInterval(10 * 60), end: now.addingTimeInterval(70 * 60))]
    let result = CalendarSlotSelector.select(slots: slots, now: now)
    #expect(result.primary == 0)
    #expect(result.secondary == nil)
}

/// An event whose end has just passed is neither primary nor secondary.
@Test func selectIgnoresAlreadyEndedEvent() {
    let now = Date(timeIntervalSince1970: 0)
    let slots = [
        EventSlot(start: now.addingTimeInterval(-60 * 60), end: now.addingTimeInterval(-60)),
        EventSlot(start: now.addingTimeInterval(5 * 60), end: now.addingTimeInterval(35 * 60)),
    ]
    let result = CalendarSlotSelector.select(slots: slots, now: now)
    #expect(result.primary == 1)
    #expect(result.secondary == nil)
}

@Test func selectReturnsNothingWhenAllEventsEnded() {
    let now = Date(timeIntervalSince1970: 0)
    let slots = [EventSlot(start: now.addingTimeInterval(-90 * 60), end: now.addingTimeInterval(-30 * 60))]
    let result = CalendarSlotSelector.select(slots: slots, now: now)
    #expect(result.primary == nil)
    #expect(result.secondary == nil)
}
