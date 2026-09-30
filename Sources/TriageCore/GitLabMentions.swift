import Foundation

/// Someone @mentioned the viewer on GitLab, from their To-Do list. Pending or done doesn't matter: GitLab marks a
/// to-do done when you open or react to it, and most people never clear the list, so neither says "answered".
/// A reply from you in the mention's thread does (`GitLabMentions.waiting`).
public struct GitLabMention: Identifiable, Hashable, Sendable {
    /// Who wrote in the mention's thread, and when: to tell whether you've replied since.
    public struct Reply: Hashable, Sendable {
        public var author: String
        public var createdAt: Date
    }

    /// `gitlab-mention:` + the to-do's id, which is per mention.
    public var id: String
    public var author: String
    public var isBot: Bool
    /// "tiger !96285": the project's name and the MR or issue reference.
    public var target: String
    public var targetTitle: String
    /// The MR or issue is still open. Merged or closed, there's nothing left to answer.
    public var targetOpen: Bool
    /// The comment itself, else the MR or issue.
    public var url: URL
    /// The comment's first line or so, for rows and banners.
    public var excerpt: String
    /// The whole comment, for the detail view.
    public var body: String
    public var createdAt: Date
    /// The last notes in the thread, the mention's own included.
    public var thread: [Reply]

    public static let idPrefix = "gitlab-mention:"

    /// Dismissed and snoozed ids are shared with PR items and Linear pings; each source prunes only its own.
    public static func isMentionID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    public init(
        id: String, author: String, isBot: Bool = false, target: String, targetTitle: String,
        targetOpen: Bool = true, url: URL, excerpt: String, body: String? = nil, createdAt: Date,
        thread: [Reply] = []
    ) {
        self.id = id
        self.author = author
        self.isBot = isBot
        self.target = target
        self.targetTitle = targetTitle
        self.targetOpen = targetOpen
        self.url = url
        self.excerpt = excerpt
        self.body = body ?? excerpt
        self.createdAt = createdAt
        self.thread = thread
    }
}

public enum GitLabMentions {
    /// Mentions older than this are dropped, as for Linear pings.
    public static let window: TimeInterval = 30 * 24 * 3600

    /// The mentions still waiting on you, newest first: from a person, not yourself, on an open MR or issue,
    /// within the window, and with no reply from you in the thread since.
    public static func waiting(_ mentions: [GitLabMention], viewer: String, now: Date) -> [GitLabMention] {
        mentions.filter { m in
            !m.isBot && m.author != viewer && m.targetOpen && now.timeIntervalSince(m.createdAt) < window
                && !m.thread.contains { $0.author == viewer && $0.createdAt > m.createdAt }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}

extension GitLabClient {
    /// The newest mentions, newest first, with their threads' last notes.
    public func mentions() async throws -> [GitLabMention] {
        let data: MentionsData = try await graphql(Self.mentionsQuery, variables: [:])
        return data.mentions()
    }

    static let mentionsQuery = """
        query {
          currentUser {
            todos(action: [mentioned, directly_addressed], state: [pending, done], first: 50) { nodes {
              id createdAt body targetUrl
              author { username name bot }
              note { url body discussion { notes(last: 20) { nodes { createdAt author { username } } } } }
              target {
                __typename
                ... on MergeRequest { state reference(full: true) title }
                ... on Issue { state reference(full: true) title }
              }
            } }
          }
        }
        """
}

/// The last notes of a mention's thread, to see whether you've replied since.
struct MentionThread: Decodable {
    struct Note: Decodable {
        struct Author: Decodable { let username: String }
        let createdAt: Date
        let author: Author?
    }
    let notes: Conn<Note>
}

struct MentionsData: Decodable {
    struct Todo: Decodable {
        struct Note: Decodable {
            let url: String?
            let body: String?
            let discussion: MentionThread?
        }
        struct Target: Decodable {
            let state: String?
            let reference: String?
            let title: String?
        }
        let id: String, createdAt: Date, body: String?, targetUrl: String?
        let author: GLUser?
        let note: Note?
        let target: Target?
    }
    struct User: Decodable {
        struct Todos: Decodable { let nodes: [Todo] }
        let todos: Todos
    }
    let currentUser: User?

    func mentions() -> [GitLabMention] {
        (currentUser?.todos.nodes ?? []).compactMap { t in
            // Only web links: the URL is what a click opens.
            let link = [t.note?.url, t.targetUrl].compactMap { $0.flatMap(URL.init(string:)) }
                .first { $0.scheme == "https" }
            guard let url = link, let author = t.author else { return nil }
            let body = t.note?.body ?? t.body ?? ""
            let thread = t.note?.discussion?.notes.nodes.compactMap { n in
                n.author.map { GitLabMention.Reply(author: $0.username, createdAt: n.createdAt) }
            }
            return GitLabMention(
                id: GitLabMention.idPrefix + t.id, author: author.login, isBot: author.isBot,
                target: Self.shortReference(t.target?.reference ?? ""), targetTitle: t.target?.title ?? "",
                // Nil (a target type not asked for) counts as open rather than hiding the mention.
                targetOpen: t.target?.state.map { $0 == "opened" } ?? true, url: url,
                excerpt: String(body.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200)),
                body: body, createdAt: t.createdAt, thread: thread ?? [])
        }
    }

    /// "group/sub/tiger!96285" → "tiger !96285", as the inbox writes it.
    static func shortReference(_ full: String) -> String {
        guard let mark = full.firstIndex(where: { $0 == "!" || $0 == "#" }) else { return full }
        let project = full[..<mark].split(separator: "/").last.map(String.init) ?? ""
        return project.isEmpty ? String(full[mark...]) : "\(project) \(full[mark...])"
    }
}

// MARK: - Notifications

/// A banner per new mention from a person; more than a few at once become one summary.
public enum MentionAlert: Hashable, Sendable {
    case new(GitLabMention)
    case summary(count: Int, newest: GitLabMention)

    /// What a click opens.
    public var url: URL {
        switch self {
        case .new(let m), .summary(_, let m): m.url
        }
    }

    public var title: String {
        switch self {
        case .new(let m): "\(m.author) mentioned you"
        case .summary(let count, _): "\(count) new GitLab mentions"
        }
    }

    public var subtitle: String {
        switch self {
        case .new(let m): m.targetTitle.isEmpty ? m.target : "\(m.target) · \(m.targetTitle)"
        case .summary: ""
        }
    }

    public var body: String {
        switch self {
        case .new(let m): m.excerpt
        case .summary(_, let newest): "Latest: \(newest.author) on \(newest.target)"
        }
    }
}

/// Which mentions were seen, persisted so each notifies once, even across restarts.
public struct MentionAlertState: Codable, Sendable, Equatable {
    /// False until the first fetch, which only records what's already there.
    public var started = false
    public var seen: Set<String> = []

    public init() {}
}

public enum MentionAlerts {
    public static let summaryThreshold = 3

    /// `mentions` is the newest page. Seen ids that fell off it are forgotten: the list is newest first, so an
    /// old mention never comes back onto it.
    public static func plan(
        _ mentions: [GitLabMention], viewer: String?, state: MentionAlertState
    ) -> (alerts: [MentionAlert], state: MentionAlertState) {
        var next = state
        let ids = Set(mentions.map(\.id))
        next.seen = state.seen.intersection(ids).union(ids)
        next.started = true
        guard state.started else { return ([], next) }

        // Bots (review bots quoting you) and your own mentions of yourself aren't pings.
        let fresh = mentions.filter { !state.seen.contains($0.id) && !$0.isBot && $0.author != viewer }
        if fresh.count > summaryThreshold, let newest = fresh.max(by: { $0.createdAt < $1.createdAt }) {
            return ([.summary(count: fresh.count, newest: newest)], next)
        }
        return (fresh.map(MentionAlert.new), next)
    }
}
