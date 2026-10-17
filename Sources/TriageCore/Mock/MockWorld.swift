import Foundation

/// A scenario turned into the app's own types, and the fake clients that serve them.
public final class MockWorld: Sendable {
    public let scenario: MockScenario
    public let githubViewer: String
    /// The GitHub repos the app starts out watching.
    public let repos: [RepoRef]
    public let gitlabHost: String?
    public let gitlabViewer: String?
    /// Linear is on for a scenario that has pings.
    public let hasLinear: Bool

    private let store: MockStore
    private let linearSource: MockLinear
    private let mentionList: [GitLabMention]

    public init(_ scenario: MockScenario, now: Date = Date()) throws {
        self.scenario = scenario
        githubViewer = scenario.github.viewer
        gitlabHost = scenario.gitlab?.host
        gitlabViewer = scenario.gitlab?.viewer
        repos = try scenario.github.repos.map { text in
            guard let repo = RepoRef(string: text) else {
                throw MockError.invalid("repo \"\(text)\" is not owner/name")
            }
            return repo
        }
        let pullRequests = try scenario.pullRequests.map { try Self.pullRequest($0, scenario: scenario, now: now) }
        let numbers = pullRequests.map(\.id)
        if let dup = Dictionary(grouping: numbers, by: { $0 }).first(where: { $1.count > 1 })?.key {
            throw MockError.invalid("pull request \(dup) is listed twice")
        }
        store = MockStore(pullRequests)
        let pings = scenario.linear ?? []
        hasLinear = !pings.isEmpty
        linearSource = MockLinear(
            notifications: try pings.enumerated().map { try Self.notification($1, index: $0, now: now) })
        mentionList = (scenario.mentions ?? []).map { Self.mention($0, now: now) }
    }

    /// The client for `forge`. A forge the scenario does not describe is an error, never a real client.
    public func forgeClient(_ forge: Forge, repos: [RepoRef] = []) throws -> any ForgeClient {
        switch forge {
        case .github:
            return MockForge(
                forge: .github, viewerLogin: githubViewer, watched: repos, store: store, mentions: [],
                diff: scenario.diff, ciLog: scenario.ciLog)
        case .gitlab(let host):
            guard host == gitlabHost, let viewer = gitlabViewer else { throw MockError.blocked("GitLab host \(host)") }
            return MockForge(
                forge: forge, viewerLogin: viewer, watched: [], store: store, mentions: mentionList,
                diff: scenario.diff, ciLog: scenario.ciLog)
        }
    }

    public func linear() -> any LinearSource { linearSource }

    public func explainer() -> any Explainer { MockExplainer(answer: scenario.explanation) }
}

// MARK: - The fake forge

/// Pull requests held in memory, shared by every client the world hands out, so an approve or a merge in the app
/// is still there at the next refresh.
final class MockStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pullRequests: [PullRequest]

    init(_ pullRequests: [PullRequest]) { self.pullRequests = pullRequests }

    func all() -> [PullRequest] { lock.withLock { pullRequests } }

    func remove(_ pr: PullRequest) { lock.withLock { pullRequests.removeAll { $0.id == pr.id } } }

    func approve(_ pr: PullRequest, as viewer: String) {
        lock.withLock {
            guard let i = pullRequests.firstIndex(where: { $0.id == pr.id }) else { return }
            pullRequests[i].approvedBy.insert(viewer)
            pullRequests[i].requestedReviewers.remove(viewer)
            if pullRequests[i].reviewDecision == .reviewRequired { pullRequests[i].reviewDecision = .approved }
        }
    }
}

struct MockForge: ForgeClient, MentionsSource {
    let forge: Forge
    let viewerLogin: String
    /// The repos the app is watching; GitLab ignores it, as the real one does.
    let watched: [RepoRef]
    let store: MockStore
    let mentions: [GitLabMention]
    let diff: String?
    let ciLog: String?

    func viewer() async throws -> String { viewerLogin }

    func fetch() async throws -> [RepoResult] {
        let mine = store.all().filter { $0.repo.forge == forge }
        let repos: [RepoRef]
        switch forge {
        case .github: repos = watched
        case .gitlab: repos = Array(Set(mine.map(\.repo)))
        }
        return repos.sorted { $0.id < $1.id }.map { repo in
            RepoResult(
                repo: repo,
                result: .success(RepoSnapshot(pullRequests: mine.filter { $0.repo == repo })))
        }
    }

    func mentions() async throws -> [GitLabMention] { mentions }

    func ciLog(_ pr: PullRequest, checkRunID: Int) async -> String? { ciLog }
    func diff(_ pr: PullRequest) async -> String? { diff }

    func approve(_ pr: PullRequest) async throws { store.approve(pr, as: viewerLogin) }

    func merge(_ pr: PullRequest) async throws {
        guard forge.capabilities.contains(.merge) else { throw ForgeError.unsupported(forge) }
        store.remove(pr)
    }

    func close(_ pr: PullRequest) async throws {
        guard forge.capabilities.contains(.close) else { throw ForgeError.unsupported(forge) }
        store.remove(pr)
    }
}

struct MockLinear: LinearSource {
    let notifications: [LinearNotification]

    func notifications() async throws -> (notifications: [LinearNotification], warnings: [String]) {
        (notifications, [])
    }
}

struct MockExplainer: Explainer {
    let answer: String?

    static let fallback = "This is a mock answer. In the real app, Claude explains the item here."

    func complete(system: String, prompt: String) async throws -> String { answer ?? Self.fallback }
}

// MARK: - Scenario → app types

private typealias Choice = CaseIterable & RawRepresentable<String>

extension MockWorld {
    static func pullRequest(_ p: MockScenario.PRSpec, scenario: MockScenario, now: Date) throws -> PullRequest {
        let repo: RepoRef
        let path: String
        switch p.forge ?? "github" {
        case "github":
            guard let r = RepoRef(string: p.repo) else {
                throw MockError.invalid("repo \"\(p.repo)\" is not owner/name")
            }
            repo = r
            path = "pull"
        case "gitlab":
            guard let gitlab = scenario.gitlab else {
                throw MockError.invalid("\(p.repo)!\(p.number) is on gitlab but the scenario has no \"gitlab\"")
            }
            guard let r = RepoRef(gitlabPath: p.repo, host: gitlab.host) else {
                throw MockError.invalid("GitLab project \"\(p.repo)\" needs a group, as group/project")
            }
            repo = r
            path = "-/merge_requests"
        case let other:
            throw MockError.invalid("forge \"\(other)\" is not github or gitlab")
        }
        func ago(_ hours: Double?) -> Date { now.addingTimeInterval(-(hours ?? 0) * 3600) }
        let url = repo.url.appending(path: path).appendingPathComponent(String(p.number))
        return PullRequest(
            repo: repo, number: p.number, title: p.title, url: url, author: p.author, isDraft: p.draft ?? false,
            createdAt: ago(p.createdHoursAgo), updatedAt: ago(p.updatedHoursAgo ?? p.createdHoursAgo),
            headSha: p.headSha ?? stableSha("\(repo.id)#\(p.number)"), headRef: p.headRef ?? "branch-\(p.number)",
            mergeable: try pick(p.mergeable, .mergeable, "mergeable"),
            reviewDecision: try pick(p.reviewDecision, .none, "reviewDecision"),
            approvedBy: Set(p.approvedBy ?? []), requestedReviewers: Set(p.requestedReviewers ?? []),
            checks: try (p.checks ?? []).map { c in
                CheckInfo(
                    name: c.name, state: try pick(c.state, .neutral, "check state"),
                    checkRunID: c.checkRunID, summary: c.summary)
            },
            threads: (p.threads ?? []).map { t in
                let first = CommentInfo(
                    author: t.author, isBot: t.isBot ?? false, body: t.body, createdAt: ago(t.hoursAgo))
                let replies = (t.replies ?? []).map { comment($0, now: now) }
                return ReviewThreadInfo(
                    isResolved: t.resolved ?? false, isOutdated: t.outdated ?? false, path: t.path, line: t.line,
                    firstComment: first, commentCount: 1 + replies.count, replies: replies)
            },
            comments: (p.comments ?? []).map { comment($0, now: now) }, summary: p.summary,
            mergeMethod: try pick(p.mergeMethod, .merge, "mergeMethod"))
    }

    private static func comment(_ c: MockScenario.Comment, now: Date) -> CommentInfo {
        CommentInfo(
            author: c.author, isBot: c.isBot ?? false, body: c.body,
            createdAt: now.addingTimeInterval(-(c.hoursAgo ?? 0) * 3600))
    }

    /// An enum by its raw value, naming the field and the choices when it is wrong.
    private static func pick<T: Choice>(_ s: String?, _ d: T, _ f: String) throws -> T {
        guard let s else { return d }
        guard let v = T(rawValue: s) else {
            let choices = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw MockError.invalid("\(f) \"\(s)\" is not one of \(choices)")
        }
        return v
    }

    /// A stable 40-hex head, so a scenario that names none still gives the same id on every run.
    static func stableSha(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var out = ""
        for round in 0..<5 {
            for byte in text.utf8 + [UInt8(round)] {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            out += String(format: "%08llx", hash & 0xffff_ffff)
        }
        return out
    }

    static func mention(_ m: MockScenario.Mention, now: Date) -> GitLabMention {
        let id = GitLabMention.isMentionID(m.id) ? m.id : "\(GitLabMention.idPrefix)\(m.id)"
        let created = now.addingTimeInterval(-m.hoursAgo * 3600)
        let line = m.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? m.body
        return GitLabMention(
            id: id, author: m.author, isBot: m.isBot ?? false, target: m.target, targetTitle: m.targetTitle,
            targetOpen: m.targetOpen ?? true,
            url: URL(string: "https://gitlab.mock.invalid/\(m.id)") ?? URL(fileURLWithPath: "/"),
            excerpt: line, body: m.body, createdAt: created,
            thread: (m.replies ?? []).map {
                .init(author: $0.author, createdAt: now.addingTimeInterval(-($0.hoursAgo ?? 0) * 3600))
            })
    }

    /// A Linear notification built in Linear's own JSON shape and decoded by the real decoder, so a field the real
    /// model reads can't be left out.
    static func notification(_ p: MockScenario.Ping, index: Int, now: Date) throws -> LinearNotification {
        let isReply: Bool
        switch p.kind {
        case "mention": isReply = false
        case "reply": isReply = true
        default: throw MockError.invalid("linear kind \"\(p.kind)\" is not mention or reply")
        }
        let id = p.id ?? "\(index + 1)"
        let created = now.addingTimeInterval(-p.hoursAgo * 3600).formatted(Self.isoFractional)
        let issueURL = "https://linear.mock.invalid/issue/\(p.issue)"
        var comment: [String: Any] = [
            "id": "comment-\(id)", "body": p.body, "url": "\(issueURL)#comment-\(id)", "createdAt": created,
            "resolvedAt": NSNull(), "children": ["nodes": [Any]()], "parent": NSNull(),
        ]
        if isReply {
            comment["parent"] = [
                "id": "thread-\(id)", "resolvedAt": NSNull(), "user": ["isMe": true],
                "children": ["nodes": [Any]()],
            ]
        }
        let json: [String: Any] = [
            "id": "notification-\(id)", "type": isReply ? "issueNewComment" : "issueCommentMention",
            "category": isReply ? "commentsAndReplies" : "mentions", "createdAt": created,
            "snoozedUntilAt": NSNull(), "actor": ["name": p.actor, "avatarUrl": NSNull(), "isMe": false],
            "issue": [
                "identifier": p.issue, "title": p.issueTitle, "url": issueURL, "state": ["type": "started"],
                "completedAt": NSNull(), "canceledAt": NSNull(), "comments": ["nodes": [Any]()],
            ],
            "comment": comment,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try gitlabDecoder.decode(LinearNotification.self, from: data)
    }

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
