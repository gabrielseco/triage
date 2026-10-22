import Foundation

/// One repo's open PRs, plus anything the query had to leave out.
public struct RepoSnapshot: Sendable {
    public var pullRequests: [PullRequest]
    /// Caps hit (PRs, checks, review threads); shown, but not treated as errors.
    public var warnings: [String]
    /// The account-wide GraphQL budget as this query left it.
    public var rateLimit: RateLimit?

    public struct RateLimit: Sendable, Equatable {
        public let remaining: Int
        public let resetAt: Date

        public init(remaining: Int, resetAt: Date) {
            self.remaining = remaining
            self.resetAt = resetAt
        }
    }

    /// Remaining GraphQL points (of 5,000/hour) below which a refresh warns.
    static let lowRateLimit = 500

    public init(pullRequests: [PullRequest], warnings: [String] = [], rateLimit: RateLimit? = nil) {
        self.pullRequests = pullRequests
        self.warnings = warnings
        self.rateLimit = rateLimit
    }

    /// Several repos' snapshots as one. They share one rate limit, so the lowest reading (the latest) is kept.
    /// Warnings are sorted: repos finish in any order, and the sidebar shouldn't reshuffle every refresh.
    public static func merging(_ snapshots: [RepoSnapshot]) -> RepoSnapshot {
        RepoSnapshot(
            pullRequests: snapshots.flatMap(\.pullRequests),
            warnings: snapshots.flatMap(\.warnings).sorted(),
            rateLimit: snapshots.compactMap(\.rateLimit).min { $0.remaining < $1.remaining })
    }

    /// Everything to show, with the rate limit as a single line when it's running low.
    public var allWarnings: [String] {
        guard let rateLimit, rateLimit.remaining < Self.lowRateLimit else { return warnings }
        let reset = rateLimit.resetAt.formatted(date: .omitted, time: .shortened)
        return warnings + ["GitHub API: \(rateLimit.remaining) points left until \(reset)"]
    }
}
