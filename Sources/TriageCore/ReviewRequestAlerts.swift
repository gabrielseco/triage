import Foundation

/// A banner when someone asks for the viewer's review, so it doesn't wait for the next digest. Once per request:
/// the item stays in the inbox until reviewed, which is the reminder.
public enum ReviewRequestAlert: Hashable, Sendable {
    case new(AttentionItem)
    /// Too many at once to show one by one (a repo just added, a batch of requests).
    case summary(count: Int)

    /// The item a click selects, if there's exactly one.
    public var item: AttentionItem? {
        guard case .new(let item) = self else { return nil }
        return item
    }

    public var title: String {
        switch self {
        case .new(let item): "Review requested: \(item.pr.repo.name) \(item.pr.ref)"
        case .summary(let count): "\(count) reviews requested"
        }
    }

    public var subtitle: String {
        switch self {
        case .new(let item): "by \(item.pr.author)"
        case .summary: ""
        }
    }

    public var body: String {
        switch self {
        case .new(let item): item.pr.title
        case .summary: "Open Triage to see them."
        }
    }
}

/// Which review requests were notified, persisted so a request notifies once, even across restarts.
public struct ReviewRequestAlertState: Codable, Sendable, Equatable {
    public struct Notified: Codable, Sendable, Equatable {
        /// `PullRequest.id`, to tell "reviewed" (its PR came back without the request) from "not fetched".
        public var prID: String
        public var lastSeen: Date
    }

    /// False until the first complete refresh, which only records what's already there.
    public var started = false
    /// By item id.
    public var notified: [String: Notified] = [:]

    public init() {}
}

public enum ReviewRequestAlerts {
    /// More new requests than this at once become one summary banner.
    public static let summaryThreshold = 3
    /// A request whose PR hasn't been fetched for this long is gone (merged, closed, repo removed).
    public static let forgetAfter: TimeInterval = 24 * 3600

    /// What one refresh saw.
    public struct Refresh: Sendable {
        /// Every review-requested item, hidden ones included, so a dismissed request is remembered and isn't
        /// announced when it's shown again.
        public var open: [AttentionItem]
        /// The ones not dismissed or snoozed in Triage: only these notify.
        public var active: [AttentionItem]
        /// Ids of the PRs returned. One that's missing (a failed repo or merge request) keeps its request
        /// remembered, or the next refresh would announce it again.
        public var fetched: Set<String>
        /// Whether every repo fetched; the first run waits for one.
        public var complete: Bool

        public init(open: [AttentionItem], active: [AttentionItem], fetched: Set<String>, complete: Bool) {
            self.open = open
            self.active = active
            self.fetched = fetched
            self.complete = complete
        }
    }

    public static func plan(
        _ refresh: Refresh, state: ReviewRequestAlertState, now: Date
    ) -> (alerts: [ReviewRequestAlert], state: ReviewRequestAlertState) {
        let (open, active, fetched, complete) = (refresh.open, refresh.active, refresh.fetched, refresh.complete)
        var next = state
        let openIDs = Set(open.map(\.id))
        // Reviewed (or the request withdrawn): forget it, so being asked again notifies again.
        next.notified = next.notified.filter { id, n in
            openIDs.contains(id) || (!fetched.contains(n.prID) && now.timeIntervalSince(n.lastSeen) < forgetAfter)
        }
        for item in open { next.notified[item.id] = .init(prID: item.pr.id, lastSeen: now) }

        guard state.started else {
            // First run: what's already waiting shows in the list, without a flood of banners. Not started until
            // a complete refresh, or a repo that failed this time would announce everything it has next time.
            next.started = complete
            return ([], next)
        }

        let fresh = active.filter { state.notified[$0.id] == nil }
        let alerts: [ReviewRequestAlert] =
            fresh.count > summaryThreshold ? [.summary(count: fresh.count)] : fresh.map(ReviewRequestAlert.new)
        return (alerts, next)
    }
}
