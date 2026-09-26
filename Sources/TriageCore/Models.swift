import Foundation

public struct RepoRef: Hashable, Codable, Sendable, Identifiable {
    public let owner: String
    public let name: String

    public var id: String { fullName }
    public var fullName: String { "\(owner)/\(name)" }

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
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
    public var updatedAt: Date
    public var headSha: String
    public var headRef: String
    public var mergeable: Mergeable
    public var reviewDecision: ReviewDecision
    public var checks: [CheckInfo]
    public var threads: [ReviewThreadInfo]
    public var comments: [CommentInfo]

    public var id: String { "\(repo.fullName)#\(number)" }

    public init(
        repo: RepoRef, number: Int, title: String, url: URL, author: String, authorAvatar: URL? = nil,
        isDraft: Bool = false,
        updatedAt: Date = .now, headSha: String, headRef: String = "branch",
        mergeable: Mergeable = .mergeable, reviewDecision: ReviewDecision = .none,
        checks: [CheckInfo] = [], threads: [ReviewThreadInfo] = [], comments: [CommentInfo] = []
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.authorAvatar = authorAvatar
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.headSha = headSha
        self.headRef = headRef
        self.mergeable = mergeable
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.threads = threads
        self.comments = comments
    }
}

public enum AttentionKind: String, CaseIterable, Sendable, Codable {
    case ciFailure, mergeConflict, changesRequested, reviewThreads, botFinding, readyToMerge, awaitingChecks,
        awaitingReview

    public var title: String {
        switch self {
        case .ciFailure: "CI failing"
        case .mergeConflict: "Merge conflict"
        case .changesRequested: "Changes requested"
        case .reviewThreads: "Unresolved review"
        case .botFinding: "Bot finding"
        case .readyToMerge: "Ready to merge"
        case .awaitingChecks: "Waiting on CI"
        case .awaitingReview: "Waiting for review"
        }
    }

    public var symbol: String {
        switch self {
        case .ciFailure: "xmark.octagon.fill"
        case .mergeConflict: "arrow.triangle.merge"
        case .changesRequested: "hand.raised.fill"
        case .reviewThreads: "text.bubble.fill"
        case .botFinding: "cpu"
        case .readyToMerge: "checkmark.seal.fill"
        case .awaitingChecks: "clock.arrow.circlepath"
        case .awaitingReview: "hourglass"
        }
    }

    /// Whether an AI "explain + propose fix" makes sense for this kind.
    public var isFixable: Bool {
        switch self {
        case .ciFailure, .mergeConflict, .changesRequested, .reviewThreads, .botFinding: true
        case .readyToMerge, .awaitingChecks, .awaitingReview: false
        }
    }

    /// Nothing for you to do yet: listed under its own filter and its repo, but kept out of Everything,
    /// the badge counts and digests, so a repo full of other people's open PRs doesn't bury what needs you.
    public var isPassive: Bool {
        switch self {
        case .awaitingChecks, .awaitingReview: true
        case .ciFailure, .mergeConflict, .changesRequested, .reviewThreads, .botFinding, .readyToMerge: false
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

public struct PRStats: Sendable, Hashable {
    public var noiseComments = 0
    public var pendingChecks = 0
    public init(noiseComments: Int = 0, pendingChecks: Int = 0) {
        self.noiseComments = noiseComments
        self.pendingChecks = pendingChecks
    }
}
