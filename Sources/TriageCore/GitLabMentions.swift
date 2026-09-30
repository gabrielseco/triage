import Foundation

/// Someone @mentioned the viewer on GitLab, from their To-Do list. Pending or done doesn't matter: GitLab marks a
/// to-do done when you open or react to it, and most people never clear the list, so neither says "answered".
public struct GitLabMention: Identifiable, Hashable, Sendable {
    /// The to-do's id, which is per mention.
    public var id: String
    public var author: String
    public var isBot: Bool
    /// "tiger !96285": the project's name and the MR or issue reference.
    public var target: String
    public var targetTitle: String
    /// The comment itself, else the MR or issue.
    public var url: URL
    public var excerpt: String
    public var createdAt: Date
}

extension GitLabClient {
    /// The newest mentions, newest first. The page only needs to cover what can arrive between two polls.
    public func mentions() async throws -> [GitLabMention] {
        let data: MentionsData = try await graphql(Self.mentionsQuery, variables: [:])
        return data.mentions()
    }

    static let mentionsQuery = """
        query {
          currentUser {
            todos(action: [mentioned, directly_addressed], state: [pending, done], first: 20) { nodes {
              id createdAt body targetUrl
              author { username name bot }
              note { url body }
              target {
                __typename
                ... on MergeRequest { reference(full: true) title }
                ... on Issue { reference(full: true) title }
              }
            } }
          }
        }
        """
}

struct MentionsData: Decodable {
    struct Todo: Decodable {
        struct Note: Decodable {
            let url: String?
            let body: String?
        }
        struct Target: Decodable {
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
            // Only web links: the URL is what a notification click opens.
            let link = [t.note?.url, t.targetUrl].compactMap { $0.flatMap(URL.init(string:)) }
                .first { $0.scheme == "https" }
            guard let url = link, let author = t.author else { return nil }
            let text = (t.note?.body ?? t.body ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            return GitLabMention(
                id: t.id, author: author.login, isBot: author.isBot,
                target: Self.shortReference(t.target?.reference ?? ""), targetTitle: t.target?.title ?? "",
                url: url, excerpt: String(text.prefix(200)), createdAt: t.createdAt)
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
