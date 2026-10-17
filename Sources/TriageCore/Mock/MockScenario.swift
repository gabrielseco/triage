import Foundation

/// What the app runs on in mock mode (docs/plans/MOCK.md): one JSON file with the viewer on each forge, the watched
/// repos, pull requests, Linear pings, GitLab mentions and the canned answers. Times are hours ago, so "updated
/// yesterday" stays true whenever the scenario is loaded.
public struct MockScenario: Decodable, Sendable {
    public struct GitHub: Decodable, Sendable {
        public var viewer: String
        /// The repos the app watches, as `owner/name`.
        public var repos: [String]
    }

    public struct GitLab: Decodable, Sendable {
        public var host: String
        public var viewer: String
    }

    public struct Check: Decodable, Sendable {
        public var name: String
        public var state: String
        public var summary: String?
        public var checkRunID: Int?
    }

    public struct Comment: Decodable, Sendable {
        public var author: String
        public var isBot: Bool?
        public var body: String
        public var hoursAgo: Double?
    }

    public struct Thread: Decodable, Sendable {
        public var resolved: Bool?
        public var outdated: Bool?
        public var path: String?
        public var line: Int?
        public var author: String
        public var isBot: Bool?
        public var body: String
        public var hoursAgo: Double?
        public var replies: [Comment]?
    }

    public struct PRSpec: Decodable, Sendable {
        public var repo: String
        /// `github` (default) or `gitlab`, which uses the scenario's GitLab host and `repo` as the project path.
        public var forge: String?
        public var number: Int
        public var title: String
        public var author: String
        public var draft: Bool?
        public var createdHoursAgo: Double
        public var updatedHoursAgo: Double?
        public var headSha: String?
        public var headRef: String?
        public var mergeable: String?
        public var reviewDecision: String?
        public var approvedBy: [String]?
        public var requestedReviewers: [String]?
        public var checks: [Check]?
        public var threads: [Thread]?
        public var comments: [Comment]?
        public var summary: String?
        public var mergeMethod: String?
    }

    public struct Ping: Decodable, Sendable {
        /// `mention` or `reply`.
        public var kind: String
        public var issue: String
        public var issueTitle: String
        public var actor: String
        public var body: String
        public var hoursAgo: Double
        /// Distinguishes two pings in one issue; defaults to the position in the list.
        public var id: String?
    }

    public struct Mention: Decodable, Sendable {
        public var id: String
        public var author: String
        public var isBot: Bool?
        public var target: String
        public var targetTitle: String
        public var body: String
        public var hoursAgo: Double
        public var targetOpen: Bool?
        /// Who answered in the thread since, and how long ago.
        public var replies: [Comment]?
    }

    public var name: String?
    public var github: GitHub
    public var gitlab: GitLab?
    public var pullRequests: [PRSpec]
    public var linear: [Ping]?
    public var mentions: [Mention]?
    /// What Explain answers, for any item.
    public var explanation: String?
    /// The diff and the failed check's log any PR returns.
    public var diff: String?
    public var ciLog: String?
}

public enum MockError: LocalizedError, Equatable {
    case unreadable(String)
    case invalid(String)
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): "Can't read the mock scenario: \(message)"
        case .invalid(let message): "The mock scenario is invalid: \(message)"
        case .blocked(let what): "Mock mode: \(what) is not available."
        }
    }
}

extension MockScenario {
    /// The environment variable that turns mock mode on; its value is the scenario file.
    public static let environmentKey = "TRIAGE_FIXTURE"
    public typealias Environment = [String: String]

    public static func load(from url: URL) throws -> MockScenario {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw MockError.unreadable(error.localizedDescription) }
        do { return try JSONDecoder().decode(MockScenario.self, from: data) } catch {
            throw MockError.invalid("\(url.lastPathComponent): \(Self.describe(error))")
        }
    }

    /// The scenario named by `TRIAGE_FIXTURE`, or nil when mock mode is off. A set but unusable value throws, so a
    /// typo never silently falls back to the real app.
    public static func fromEnvironment() throws -> MockScenario? {
        try fromEnvironment(ProcessInfo.processInfo.environment)
    }

    public static func fromEnvironment(_ env: Environment) throws -> MockScenario? {
        guard let path = env[environmentKey], !path.isEmpty else { return nil }
        return try load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\" at \(Self.path(context.codingPath))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(Self.path(context.codingPath))"
        @unknown default: return error.localizedDescription
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
