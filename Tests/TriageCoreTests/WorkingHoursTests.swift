import Foundation
import Testing

@testable import TriageCore

@Suite struct WorkingHoursTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // 2026-11-16 is a Monday, 2026-11-21 a Saturday.
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func insideAndOutsideOnAWeekday() {
        let hours = WorkingHours(startHour: 8, endHour: 17)
        #expect(!hours.contains(date(16, 7, 59), calendar: cal))
        #expect(hours.contains(date(16, 8), calendar: cal))
        #expect(hours.contains(date(16, 16, 59), calendar: cal))
        #expect(!hours.contains(date(16, 17), calendar: cal))
    }

    @Test func weekendsAreOutWhenWeekdaysOnly() {
        #expect(!WorkingHours().contains(date(21, 10), calendar: cal))
        #expect(WorkingHours(weekdaysOnly: false).contains(date(21, 10), calendar: cal))
    }

    @Test func overnightWindowWraps() {
        let hours = WorkingHours(startHour: 22, endHour: 6, weekdaysOnly: false)
        #expect(hours.contains(date(16, 23), calendar: cal))
        #expect(hours.contains(date(16, 5), calendar: cal))
        #expect(!hours.contains(date(16, 12), calendar: cal))
    }

    @Test func emptyWindowMeansAllDay() {
        #expect(WorkingHours(startHour: 9, endHour: 9, weekdaysOnly: false).contains(date(16, 3), calendar: cal))
    }
}
