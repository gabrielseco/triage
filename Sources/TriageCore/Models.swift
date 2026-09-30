import Foundation

public struct RepoRef: Hashable, Sendable, Identifiable {
    public let forge: Forge
    /// The namespace: a GitHub user or org, or a GitLab group path, which can nest (`group/subgroup`).
    public let owner: String
    public let name: String

    /// What dismissals, snoozes and seen PRs are keyed by. GitHub keeps plain `owner/name`, as before forges
    /// existed; GitLab leads with the host so it can't collide with a GitHub repo of the same name.
    public var id: String {
        switch forge {
        case .github: fullName
        case .gitlab(let host): "\(host)/\(fullName)"
        }
    }
    public var fullName: String { "\(owner)/\(name)" }
    /// The repo's page.
    public var url: URL {
        let base =
            switch forge {
            case .github: URL(string: "https://github.com")!
            // `init(gitlabPath:host:)` checked the host; the fallback is unreachable.
            case .gitlab(let host): URL(string: "https://\(host)") ?? URL(string: "https://gitlab.com")!
            }
        return owner.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
            .appendingPathComponent(name)
    }
    /// Its open pull (merge) requests.
    public var pullsURL: URL {
        switch forge {
        case .github: url.appendingPathComponent("pulls")
        case .gitlab: url.appendingPathComponent("-").appendingPathComponent("merge_requests")
        }
    }

    public init(owner: String, name: String, forge: Forge = .github) {
        self.forge = forge
        self.owner = owner
        self.name = name
    }

    /// A GitLab project from its full path, `group/subgroup/project`. Nil without a group, or if `host` isn't
    /// a bare host name (so `url` can't point somewhere else).
    public init?(gitlabPath path: String, host: String) {
        guard URL(string: "https://\(host)")?.host == host, let slash = path.lastIndex(of: "/") else { return nil }
        let owner = String(path[..<slash])
        let name = String(path[path.index(after: slash)...])
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        self.init(owner: owner, name: name, forge: .gitlab(host: host))
    }

    /// Accepts "owner/name" or a github.com URL.
    public init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "github.com/") { s = String(s[range.upperBound...]) }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(owner: parts[0], name: parts[1].replacingOccurrences(of: ".git", with: ""))
    }
}

/// GitHub repos encode as `{"owner","name"}`, exactly as before forges existed, so saved `repos` keep loading.
/// GitLab ones add `gitlabHost`.
extension RepoRef: Codable {
    enum CodingKeys: String, CodingKey { case owner, name, gitlabHost }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let host = try c.decodeIfPresent(String.self, forKey: .gitlabHost)
        self.init(
            owner: try c.decode(String.self, forKey: .owner), name: try c.decode(String.self, forKey: .name),
            forge: host.map { .gitlab(host: $0) } ?? .github)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(owner, forKey: .owner)
        try c.encode(name, forKey: .name)
        if case .gitlab(let host) = forge { try c.encode(host, forKey: .gitlabHost) }
    }
}

public enum CheckState: String, Sendable {
    case success, failure, pending, neutral
}

public struct CheckInfo: Hashable, Sendable {
    public var name: String
    public var state: CheckState
    public var url: URL?
    /// GitHub check run id. For GitHub Actions this is also the job id, which lets us fetch logs.
    public var checkRunID: Int?
    public var summary: String?

    public init(name: String, state: CheckState, url: URL? = nil, checkRunID: Int? = nil, summary: String? = nil) {
        self.name = name
        self.state = state
        self.url = url
        self.checkRunID = checkRunID
        self.summary = summary
    }
}

public struct CommentInfo: Hashable, Sendable {
    public var author: String
    public var isBot: Bool
    public var body: String
    public var url: URL?
    public var createdAt: Date

    public init(author: String, isBot: Bool, body: String, url: URL? = nil, createdAt: Date = .now) {
        self.author = author
        self.isBot = isBot
        self.body = body
        self.url = url
        self.createdAt = createdAt
    }
}

public struct ReviewThreadInfo: Hashable, Sendable {
    public var isResolved: Bool
    public var isOutdated: Bool
    public var path: String?
    public var line: Int?
    public var firstComment: CommentInfo
    public var commentCount: Int
    /// The thread's comments in order, first included (the query fetches up to 30).
    public var comments: [CommentInfo]

    public init(
        isResolved: Bool, isOutdated: Bool = false, path: String? = nil, line: Int? = nil,
        firstComment: CommentInfo, commentCount: Int = 1, replies: [CommentInfo] = []
    ) {
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.path = path
        self.line = line
        self.firstComment = firstComment
        self.commentCount = commentCount
        self.comments = [firstComment] + replies
    }
}

public enum Mergeable: String, Sendable {
    case mergeable = "MERGEABLE", conflicting = "CONFLICTING", unknown = "UNKNOWN"
}

public enum ReviewDecision: String, Sendable {
    case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED", none
}

public struct PullRequest: Identifiable, Hashable, Sendable {
    public var repo: RepoRef
    public var number: Int
    public var title: String
    public var url: URL
    public var author: String
    public var authorAvatar: URL?
    public var isDraft: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var headSha: String
    public var headRef: String
    public var mergeable: Mergeable
    public var reviewDecision: ReviewDecision
    /// Logins whose latest approve-or-request-changes review is an approval.
    public var approvedBy: Set<String>
    /// Logins asked for a review they haven't given yet. People only: GitHub team requests aren't expanded.
    public var requestedReviewers: Set<String>
    public var checks: [CheckInfo]
    public var threads: [ReviewThreadInfo]
    public var comments: [CommentInfo]
    /// What the PR is about, from its description (`PRSummary`). Nil when the description says nothing usable.
    public var summary: String?
    /// The method GitHub's merge button would use for the viewer: their last one, or the repo's default.
    public var mergeMethod: MergeMethod

    public var id: String { "\(repo.id)#\(number)" }
    /// The number as the forge writes it: `#12`, or `!12` for a GitLab merge request.
    public var ref: String { "\(repo.forge.numberPrefix)\(number)" }
    /// The PR's diff: GitHub's "Files changed" tab, GitLab's "Changes".
    public var changesURL: URL {
        switch repo.forge {
        case .github: url.appendingPathComponent("changes")
        case .gitlab: url.appendingPathComponent("diffs")
        }
    }
    /// Where Open goes: your own PR opens on its conversation, to see what reviewers said; anyone else's on the
    /// diff, since you're there to review it.
    public func primaryURL(viewer: String?) -> URL { author == viewer ? url : changesURL }

    public init(
        repo: RepoRef, number: Int, title: String, url: URL, author: String, authorAvatar: URL? = nil,
        isDraft: Bool = false, createdAt: Date = .distantPast,
        updatedAt: Date = .now, headSha: String, headRef: String = "branch",
        mergeable: Mergeable = .mergeable, reviewDecision: ReviewDecision = .none,
        approvedBy: Set<String> = [], requestedReviewers: Set<String> = [], checks: [CheckInfo] = [],
        threads: [ReviewThreadInfo] = [],
        comments: [CommentInfo] = [],
        summary: String? = nil, mergeMethod: MergeMethod = .merge
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.authorAvatar = authorAvatar
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.headSha = headSha
        self.headRef = headRef
        self.mergeable = mergeable
        self.reviewDecision = reviewDecision
        self.approvedBy = approvedBy
        self.requestedReviewers = requestedReviewers
        self.checks = checks
        self.threads = threads
        self.comments = comments
        self.summary = summary
        self.mergeMethod = mergeMethod
    }
}

public enum AttentionKind: String, CaseIterable, Sendable, Codable {
    case reviewRequested, ciFailure, mergeConflict, changesRequested, reviewThreads, botFinding, readyToMerge,
        awaitingChecks, awaitingReview, newPR

    public var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .ciFailure: "CI failing"
        case .mergeConflict: "Merge conflict"
        case .changesRequested: "Changes requested"
        case .reviewThreads: "Unresolved review"
        case .botFinding: "Bot finding"
        case .readyToMerge: "Ready to merge"
        case .awaitingChecks: "Waiting on CI"
        case .awaitingReview: "Waiting for review"
        case .newPR: "New PR"
        }
    }

    public var symbol: String {
        switch self {
        case .reviewRequested: "eyes"
        case .ciFailure: "xmark.octagon.fill"
        case .mergeConflict: "arrow.triangle.merge"
        case .changesRequested: "hand.raised.fill"
        case .reviewThreads: "text.bubble.fill"
        case .botFinding: "cpu"
        case .readyToMerge: "checkmark.seal.fill"
        case .awaitingChecks: "clock.arrow.circlepath"
        case .awaitingReview: "hourglass"
        case .newPR: "sparkles"
        }
    }

    /// Whether an AI "explain + propose fix" makes sense for this kind.
    public var isFixable: Bool {
        switch self {
        case .ciFailure, .mergeConflict, .changesRequested, .reviewThreads, .botFinding: true
        case .reviewRequested, .readyToMerge, .awaitingChecks, .awaitingReview, .newPR: false
        }
    }

    /// Nothing for you to do yet: listed under its own filter and its repo, but kept out of Everything,
    /// the badge counts and digests, so a repo full of other people's open PRs doesn't bury what needs you.
    public var isPassive: Bool {
        switch self {
        case .awaitingChecks, .awaitingReview: true
        case .reviewRequested, .ciFailure, .mergeConflict, .changesRequested, .reviewThreads, .botFinding,
            .readyToMerge, .newPR:
            false
        }
    }
}

public enum Severity: Int, Comparable, Sendable, CaseIterable {
    case info = 0, low, medium, high

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .info: "Info"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

public struct Evidence: Hashable, Sendable {
    public var title: String
    public var detail: String?
    public var url: URL?
    /// Set for failed checks so the prompt builder can pull logs.
    public var checkRunID: Int?

    public init(title: String, detail: String? = nil, url: URL? = nil, checkRunID: Int? = nil) {
        self.title = title
        self.detail = detail
        self.url = url
        self.checkRunID = checkRunID
    }
}

public struct AttentionItem: Identifiable, Hashable, Sendable {
    /// Stable across refreshes; changes when the underlying situation changes (new push, new thread),
    /// so a dismissed item comes back only when there's something new.
    public var id: String
    public var kind: AttentionKind
    public var severity: Severity
    public var pr: PullRequest
    public var headline: String
    public var evidence: [Evidence]
}

extension [AttentionItem] {
    /// Waiting for review reads as a queue: the most recently opened PR first, so the order doesn't reshuffle
    /// every time someone pushes to or comments on a PR in it.
    public func sortedByCreation() -> [AttentionItem] {
        sorted { ($0.pr.createdAt, $0.pr.number) > ($1.pr.createdAt, $1.pr.number) }
    }
}

public struct PRStats: Sendable, Hashable {
    public var noiseComments = 0
    public var pendingChecks = 0
    public init(noiseComments: Int = 0, pendingChecks: Int = 0) {
        self.noiseComments = noiseComments
        self.pendingChecks = pendingChecks
    }
}

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
