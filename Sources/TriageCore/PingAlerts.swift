import Foundation

/// What to tell the user about Linear pings: a banner per new ping, then reminders until it's answered,
/// dismissed or snoozed (docs/plans/LINEAR.md › Notifications). Pure, so `now` and the schedule come in.
public enum PingAlert: Hashable, Sendable {
    /// Someone just pinged.
    case new(LinearPing)
    /// Still open since the first banner, `since` ago.
    case reminder(LinearPing, since: TimeInterval)
    /// Too many new pings at once to show one by one; `newest` is where a click lands.
    case summary(count: Int, newest: LinearPing)

    /// The ping a click opens, if there's exactly one.
    public var ping: LinearPing? {
        switch self {
        case .new(let p), .reminder(let p, _): p
        case .summary: nil
        }
    }

    public var title: String {
        switch self {
        case .new(let p): p.headline
        case .reminder(let p, _): "Still waiting: \(p.headline)"
        case .summary(let count, _): "\(count) new Linear pings"
        }
    }

    public var subtitle: String {
        switch self {
        case .new(let p): "\(p.issueKey) · \(p.issueTitle)"
        case .reminder(let p, let since): "\(p.issueKey) · \(Self.ago(since))"
        case .summary: ""
        }
    }

    public var body: String {
        switch self {
        case .new(let p), .reminder(let p, _): p.excerpt
        case .summary(_, let newest): "Latest: \(newest.headline) · \(newest.issueKey)"
        }
    }

    /// Notifications for one issue stack together in Notification Center.
    public var threadIdentifier: String {
        switch self {
        case .new(let p), .reminder(let p, _): "linear:\(p.issueKey)"
        case .summary: "linear"
        }
    }

    /// "1 h ago", "2 d ago": short enough for a subtitle.
    static func ago(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3600)
        return hours < 24 ? "\(max(hours, 1)) h ago" : "\(hours / 24) d ago"
    }
}

/// Which pings were notified and when, persisted so a ping notifies once, even across restarts.
public struct PingAlertState: Codable, Sendable, Equatable {
    public struct Notified: Codable, Sendable, Equatable {
        /// The first banner; reminders count from here.
        public var firstAt: Date
        /// How many reminders have gone out.
        public var reminders: Int
    }

    /// False until the first fetch after turning Linear on, which only records what's already there.
    public var started = false
    public var notified: [String: Notified] = [:]

    public init() {}
}

public enum PingAlerts {
    /// Reminders go out this long after the first banner, then every `daily` after the last offset.
    public static let reminderOffsets: [TimeInterval] = [3600, 4 * 3600]
    public static let daily: TimeInterval = 24 * 3600
    /// More new pings than this at once become one summary banner.
    public static let summaryThreshold = 3

    /// - Parameters:
    ///   - open: every open ping from the last fetch, hidden ones included, so a dismissed ping isn't forgotten
    ///     and then announced again as new when it's restored.
    ///   - active: the ones not dismissed or snoozed in Triage: only these notify.
    public static func plan(
        open: [LinearPing], active: [LinearPing], state: PingAlertState, now: Date
    ) -> (alerts: [PingAlert], state: PingAlertState) {
        var next = state
        // Answered, or replaced by a newer ping in the same thread: forget it.
        let openIDs = Set(open.map(\.id))
        next.notified = next.notified.filter { openIDs.contains($0.key) }

        guard state.started else {
            // First run: what's already waiting shows in the list, without a flood of banners.
            for p in open { next.notified[p.id] = .init(firstAt: now, reminders: 0) }
            next.started = true
            return ([], next)
        }

        var alerts: [PingAlert] = []
        let fresh = active.filter { next.notified[$0.id] == nil }
        if fresh.count > summaryThreshold, let newest = fresh.max(by: { $0.pingedAt < $1.pingedAt }) {
            alerts.append(.summary(count: fresh.count, newest: newest))
        } else {
            alerts += fresh.map(PingAlert.new)
        }
        for p in fresh { next.notified[p.id] = .init(firstAt: now, reminders: 0) }

        for p in active {
            guard var n = next.notified[p.id], fresh.allSatisfy({ $0.id != p.id }) else { continue }
            let due = remindersDue(since: now.timeIntervalSince(n.firstAt))
            guard due > n.reminders else { continue }
            // Several overdue (after a snooze or the Mac asleep): one reminder, not a burst.
            alerts.append(.reminder(p, since: now.timeIntervalSince(n.firstAt)))
            n.reminders = due
            next.notified[p.id] = n
        }
        return (alerts, next)
    }

    /// How many reminders should have gone out `elapsed` after the first banner: one per offset passed, then
    /// one per day.
    static func remindersDue(since elapsed: TimeInterval) -> Int {
        let fixed = reminderOffsets.filter { elapsed >= $0 }.count
        guard let last = reminderOffsets.last, elapsed >= last else { return fixed }
        return fixed + Int((elapsed - last) / daily)
    }
}
