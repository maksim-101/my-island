import Foundation
import Testing
@testable import MyIslandCore

/// 07-10-PLAN's `<behavior>` list, one test per literal example — RED phase, written against the
/// plan's own spec before `DailyTimerTotal.swift` exists. Wrapped in a `@Suite`, matching
/// `ClipboardKindTests`' own 07-09 precedent — `swift test --filter DailyTimerTotalTests` (this
/// plan's own `<verify>` command) resolves by suite name; a free `@Test func` has no
/// "DailyTimerTotalTests" in its test ID. A fixed UTC `Calendar` throughout so day-boundary math
/// never depends on the machine's own local time zone.
@Suite struct DailyTimerTotalTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    @Test func firstRecord() {
        var total = DailyTimerTotal()
        total.record(duration: 1500, at: date(2026, 9, 27, 10, 0), calendar: calendar)
        #expect(total.sessions == 1)
        #expect(total.seconds == 1500)
        #expect(total.day == "2026-09-27")
    }

    @Test func sameDayAccumulates() {
        var total = DailyTimerTotal()
        total.record(duration: 1500, at: date(2026, 9, 27, 10, 0), calendar: calendar)
        total.record(duration: 300, at: date(2026, 9, 27, 18, 0), calendar: calendar)
        #expect(total.sessions == 2)
        #expect(total.seconds == 1800)
    }

    @Test func nextDayResets() {
        var total = DailyTimerTotal()
        total.record(duration: 1500, at: date(2026, 9, 27, 10, 0), calendar: calendar)
        total.record(duration: 900, at: date(2026, 9, 28, 0, 0, 0), calendar: calendar)
        #expect(total.sessions == 1)
        #expect(total.seconds == 900)
        #expect(total.day == "2026-09-28")
    }

    @Test func midnightBoundary() {
        var total = DailyTimerTotal()
        total.record(duration: 60, at: date(2026, 9, 27, 23, 59, 59), calendar: calendar)
        let dayBefore = total.day
        total.record(duration: 60, at: date(2026, 9, 28, 0, 0, 0), calendar: calendar)
        #expect(dayBefore == "2026-09-27")
        #expect(total.day == "2026-09-28")
        #expect(dayBefore != total.day)
    }

    @Test func totalOnOtherDayIsZero() {
        var total = DailyTimerTotal()
        total.record(duration: 1500, at: date(2026, 9, 27, 10, 0), calendar: calendar)
        let result = total.total(on: date(2026, 9, 28, 10, 0), calendar: calendar)
        #expect(result.sessions == 0)
        #expect(result.seconds == 0)
    }

    @Test func roundTripsCodable() throws {
        var total = DailyTimerTotal()
        total.record(duration: 1500, at: date(2026, 9, 27, 10, 0), calendar: calendar)
        let data = try JSONEncoder().encode(total)
        let decoded = try JSONDecoder().decode(DailyTimerTotal.self, from: data)
        #expect(decoded == total)
    }
}
