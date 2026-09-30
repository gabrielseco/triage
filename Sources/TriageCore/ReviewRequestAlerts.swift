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
    /// False until the first refresh, which only records what's already there.
    public var started = false
    public var notified: Set<String> = []

    public init() {}
}

public enum ReviewRequestAlerts {
    /// More new requests than this at once become one summary banner.
    public static let summaryThreshold = 3

    /// - Parameters:
    ///   - open: every review-requested item from the last refresh, hidden ones included, so a dismissed request
    ///     isn't forgotten and then announced again when it's restored.
    ///   - active: the ones not dismissed or snoozed in Triage: only these notify.
    ///   - complete: whether every repo fetched. A repo that failed drops its items for one refresh; forgetting
    ///     them then would announce them all again on the next one.
    public static func plan(
        open: [AttentionItem], active: [AttentionItem], state: ReviewRequestAlertState, complete: Bool
    ) -> (alerts: [ReviewRequestAlert], state: ReviewRequestAlertState) {
        var next = state
        // Reviewed (or the request withdrawn): forget it, so being asked again notifies again.
        if complete { next.notified.formIntersection(open.map(\.id)) }

        guard state.started else {
            // First run: what's already waiting shows in the list, without a flood of banners. Not started until
            // a complete refresh, or a repo that failed this time would announce everything it has next time.
            next.notified.formUnion(open.map(\.id))
            next.started = complete
            return ([], next)
        }

        let fresh = active.filter { !next.notified.contains($0.id) }
        next.notified.formUnion(fresh.map(\.id))
        let alerts: [ReviewRequestAlert] =
            fresh.count > summaryThreshold ? [.summary(count: fresh.count)] : fresh.map(ReviewRequestAlert.new)
        return (alerts, next)
    }
}
