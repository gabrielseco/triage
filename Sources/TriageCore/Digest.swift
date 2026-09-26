import Foundation

public struct Digest: Sendable {
    /// Items that weren't open at the previous digest, most severe first.
    public var newItems: [AttentionItem]
    /// Items open at the previous digest that are gone now (fixed, merged, dismissed, or superseded by a push).
    public var clearedCount: Int
    public var openCount: Int
    public var title: String
    public var body: String
}

public enum DigestBuilder {
    public static func build(current: [AttentionItem], previousIDs: Set<String>, since: Date?,
                             calendar: Calendar = .current) -> Digest {
        let currentIDs = Set(current.map(\.id))
        let new = current
            .filter { !previousIDs.contains($0.id) }
            .sorted { ($0.severity, $0.pr.updatedAt) > ($1.severity, $1.pr.updatedAt) }
        let cleared = previousIDs.subtracting(currentIDs).count

        let sinceLabel = since.map { " since \(label($0, calendar: calendar))" } ?? ""
        let title = new.isEmpty ? "Nothing new\(sinceLabel)" : "\(new.count) new\(sinceLabel)"

        var lines = new.prefix(3).map { "• \($0.pr.repo.name) #\($0.pr.number) \($0.kind.title): \($0.headline)" }
        if new.count > 3 { lines.append("+\(new.count - 3) more") }
        var tally = ["\(current.count) open"]
        if cleared > 0 { tally.append("\(cleared) cleared") }
        lines.append(tally.joined(separator: " · "))

        return Digest(newItems: new, clearedCount: cleared, openCount: current.count,
                      title: title, body: lines.joined(separator: "\n"))
    }

    /// The most recent scheduled digest time at or before `now`, e.g. hours [12, 18] at 14:05 → today 12:00;
    /// at 09:00 → yesterday 18:00 (or Friday 18:00 on a Monday when weekdaysOnly).
    public static func latestSlot(atOrBefore now: Date, hours: [Int], weekdaysOnly: Bool,
                                  calendar: Calendar = .current) -> Date? {
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            if weekdaysOnly, calendar.isDateInWeekend(day) { continue }
            let slots = hours.compactMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: day) }
                .filter { $0 <= now }
            if let latest = slots.max() { return latest }
        }
        return nil
    }

    static func label(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}
