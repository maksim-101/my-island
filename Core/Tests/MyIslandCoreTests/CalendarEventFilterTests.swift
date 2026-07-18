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
