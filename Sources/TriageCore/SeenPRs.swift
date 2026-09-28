import Foundation

/// Which PRs count as new: opened after Triage started watching their repo and not dismissed yet.
/// Keyed on the PR's creation date rather than on the PRs seen so far, because a fetch only returns the most
/// recently updated open PRs, and an old PR coming back into that window isn't news.
public struct SeenPRs: Codable, Equatable, Sendable {
    public struct Repo: Codable, Equatable, Sendable {
        /// When the repo was first fetched. PRs opened before that are the backlog, not news.
        public var since: Date
        /// New PRs already dismissed. Only grows by one per dismissal, so it's never pruned.
        public var dismissed: Set<Int> = []
    }

    public var repos: [String: Repo] = [:]

    public init() {}

    /// Starts the clock for repos fetched for the first time, so adding a repo doesn't flag its open PRs.
    public mutating func startWatching(_ fetched: [RepoRef], now: Date = .now) {
        for r in fetched where repos[r.fullName] == nil { repos[r.fullName] = Repo(since: now) }
    }

    public mutating func stopWatching(_ repo: RepoRef) { repos[repo.fullName] = nil }

    /// False for a repo not fetched yet.
    public func isNew(_ pr: PullRequest) -> Bool {
        guard let r = repos[pr.repo.fullName] else { return false }
        return pr.createdAt > r.since && !r.dismissed.contains(pr.number)
    }

    public mutating func dismiss(_ pr: PullRequest) { repos[pr.repo.fullName]?.dismissed.insert(pr.number) }

    /// "Show hidden": dismissed new PRs come back like any other dismissed item.
    public mutating func undismissAll() {
        for key in repos.keys { repos[key]?.dismissed = [] }
    }
}
