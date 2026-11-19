import Foundation

/// The window automatic notifications are allowed in, e.g. 8 to 17 on weekdays. The end hour is exclusive:
/// 8–17 covers 08:00 up to 16:59.
public struct WorkingHours: Codable, Sendable, Equatable {
    public var startHour: Int
    public var endHour: Int
    public var weekdaysOnly: Bool

    public init(startHour: Int = 8, endHour: Int = 17, weekdaysOnly: Bool = true) {
        self.startHour = startHour
        self.endHour = endHour
        self.weekdaysOnly = weekdaysOnly
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        if weekdaysOnly, calendar.isDateInWeekend(date) { return false }
        let hour = calendar.component(.hour, from: date)
        if startHour == endHour { return true }  // an empty window would silence everything: read it as all day
        if startHour < endHour { return (startHour..<endHour).contains(hour) }
        return hour >= startHour || hour < endHour  // overnight, e.g. 22–6
    }
}
