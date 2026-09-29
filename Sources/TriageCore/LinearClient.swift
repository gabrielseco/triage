import Foundation

public enum LinearError: LocalizedError {
    case noKey
    case http(Int, String)
    case graphql(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: "No Linear API key. Add one in Settings → Linear."
        case .http(401, _): "Linear rejected the API key (revoked?). Create a new one with Read access."
        case .http(let code, let body): "Linear HTTP \(code): \(String(body.prefix(300)))"
        case .graphql(let msg): "Linear GraphQL: \(msg)"
        }
    }
}

public enum LinearAuth {
    /// Where Settings keeps the key: its own Keychain service, one account.
    public static let keychainService = "dev.rogal.triage.linear"
    static let keychainAccount = "api.linear.app"

    /// LINEAR_API_KEY env var, else the Keychain entry.
    public static func key() -> String? {
        if let k = ProcessInfo.processInfo.environment["LINEAR_API_KEY"], !k.isEmpty { return k }
        return Keychain.get(keychainAccount, service: keychainService)
    }
}

/// Linear's API for the viewer's notifications, read-only. `LinearPings` decides which of them need an answer
/// (docs/plans/LINEAR.md).
public struct LinearClient: Sendable {
    let key: String

    public init(key: String) {
        self.key = key
    }

    /// Pings older than this are dropped, long enough to cover a PTO.
    public static let window: TimeInterval = 30 * 24 * 3600
    /// A backstop against paging forever; 50 per page, so 500 notifications in 30 days.
    static let maxPages = 10

    /// Every unarchived notification from the last 30 days, following pages so the pings aren't lost behind
    /// assignments and status changes. Warns, rather than fails, if it stopped at `maxPages`.
    public func notifications() async throws -> (notifications: [LinearNotification], warnings: [String]) {
        var all: [LinearNotification] = []
        var after: String?
        for _ in 0..<Self.maxPages {
            var variables = ["since": "-P30D"]
            if let after { variables["after"] = after }
            let data: NotificationsData = try await graphql(Self.notificationsQuery, variables: variables)
            all += data.notifications.nodes.compactMap(\.issueNotification)
            guard data.notifications.pageInfo.hasNextPage, let next = data.notifications.pageInfo.endCursor else {
                return (all, [])
            }
            after = next
        }
        return (all, ["Linear: more than \(all.count) notifications in 30 days; older pings may be missing"])
    }

    // MARK: - Plumbing

    func graphql<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        guard let url = URL(string: "https://api.linear.app/graphql") else { throw LinearError.graphql("bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // A personal API key goes in as-is; only OAuth tokens take "Bearer".
        req.setValue(key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LinearError.http(code, String(decoding: data, as: UTF8.self)) }
        return try Self.decode(data)
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        // Linear's DateTime is ISO 8601 with fractional seconds, which the GitLab decoder already handles.
        let res = try gitlabDecoder.decode(GQLResponse<T>.self, from: data)
        if let d = res.data { return d }
        throw LinearError.graphql(res.errors?.map(\.message).joined(separator: "; ") ?? "empty response")
    }

    /// Only the viewer's own comments are fetched in each thread (`isMe`): all the rules need is whether I
    /// answered after the ping, and it keeps the query small.
    static let notificationsQuery = """
        query Pings($since: DateTimeOrDuration!, $after: String) {
          notifications(first: 50, after: $after, orderBy: createdAt, filter: { createdAt: { gt: $since } }) {
            pageInfo { hasNextPage endCursor }
            nodes {
              __typename
              ... on IssueNotification {
                id type category createdAt snoozedUntilAt
                actor { displayName avatarUrl isMe }
                issue {
                  identifier title url state { type }
                  comments(first: 20, filter: { user: { isMe: { eq: true } } }) { nodes { createdAt } }
                }
                comment {
                  id body url createdAt resolvedAt
                  children(first: 20, filter: { user: { isMe: { eq: true } } }) { nodes { createdAt } }
                  parent {
                    id resolvedAt user { isMe }
                    children(first: 20, filter: { user: { isMe: { eq: true } } }) { nodes { createdAt } }
                  }
                }
              }
            }
          }
        }
        """
}

// MARK: - GraphQL decoding

struct NotificationsData: Decodable {
    struct Page: Decodable {
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        let pageInfo: PageInfo
        let nodes: [Node]
    }
    /// Any notification; only issue notifications carry pings, the rest decode to nil.
    struct Node: Decodable {
        let issueNotification: LinearNotification?

        init(from decoder: Decoder) throws {
            struct Kind: Decodable {
                let typename: String
                enum CodingKeys: String, CodingKey { case typename = "__typename" }
            }
            let kind = try Kind(from: decoder)
            issueNotification = kind.typename == "IssueNotification" ? try LinearNotification(from: decoder) : nil
        }
    }
    let notifications: Page
}

/// One issue notification as Linear sends it, trimmed to what `LinearPings` reads.
public struct LinearNotification: Decodable, Sendable, Hashable {
    public struct Actor: Decodable, Sendable, Hashable {
        let displayName: String
        let avatarUrl: URL?
        let isMe: Bool
    }
    public struct Issue: Decodable, Sendable, Hashable {
        struct State: Decodable, Sendable, Hashable { let type: String }
        let identifier: String
        let title: String
        let url: URL
        let state: State
        /// Only mine.
        let comments: Mine.Conn
    }
    public struct Comment: Decodable, Sendable, Hashable {
        struct Parent: Decodable, Sendable, Hashable {
            struct User: Decodable, Sendable, Hashable { let isMe: Bool }
            let id: String
            let resolvedAt: Date?
            let user: User?
            /// Only mine.
            let children: Mine.Conn
        }
        let id: String
        let body: String
        let url: URL
        let createdAt: Date
        let resolvedAt: Date?
        /// Only mine.
        let children: Mine.Conn
        let parent: Parent?
    }
    /// One of my comments; only its time matters.
    public struct Mine: Decodable, Sendable, Hashable {
        struct Conn: Decodable, Sendable, Hashable { let nodes: [Mine] }
        let createdAt: Date
    }

    let id: String
    let type: String
    let category: String
    let createdAt: Date
    let snoozedUntilAt: Date?
    /// Nil for an integration or system event.
    let actor: Actor?
    let issue: Issue
    let comment: Comment?
}
