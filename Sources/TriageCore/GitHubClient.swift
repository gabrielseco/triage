import Foundation

public enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case graphql(String)

    public var errorDescription: String? {
        switch self {
        case .noToken: "No GitHub token. Set GITHUB_TOKEN or run `gh auth login`."
        case .http(let code, let body): "GitHub HTTP \(code): \(body.prefix(300))"
        case .graphql(let msg): "GitHub GraphQL: \(msg)"
        }
    }
}

public enum GitHubAuth {
    /// GITHUB_TOKEN env var, else the `gh` CLI's token. The Phoenix backend will replace this with
    /// a per-user GitHub App installation token.
    public static func resolveToken() -> String? {
        if let t = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !t.isEmpty { return t }
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: gh) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["auth", "token"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { continue }
            p.waitUntilExit()
            let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !token.isEmpty { return token }
        }
        return nil
    }
}

public struct GitHubClient: Sendable {
    let token: String
    let api = URL(string: "https://api.github.com")!

    public init(token: String) { self.token = token }

    // MARK: - GraphQL

    public func viewerLogin() async throws -> String {
        struct ViewerData: Decodable {
            struct Viewer: Decodable { let login: String }
            let viewer: Viewer
        }
        let data: ViewerData = try await graphql("query { viewer { login } }", variables: [:])
        return data.viewer.login
    }

    public func openPullRequests(_ repo: RepoRef) async throws -> RepoSnapshot {
        let d: RepoData = try await graphql(Self.prQuery, variables: ["owner": repo.owner, "name": repo.name])
        guard let r = d.repository else {
            throw GitHubError.graphql("repository \(repo.fullName) not found or not accessible")
        }
        let prs = r.pullRequests.nodes
        var warnings: [String] = []
        if r.pullRequests.totalCount > prs.count {
            let total = r.pullRequests.totalCount
            warnings.append("\(repo.fullName): showing the \(prs.count) most recently updated of \(total) open PRs")
        }
        warnings += prs.flatMap { $0.truncationWarnings(repo: repo) }
        if let rl = d.rateLimit, rl.remaining < Self.lowRateLimit {
            let reset = rl.resetAt.formatted(date: .omitted, time: .shortened)
            warnings.append("GitHub API: \(rl.remaining) points left until \(reset)")
        }
        return RepoSnapshot(pullRequests: prs.map { $0.toModel(repo: repo) }, warnings: warnings)
    }

    /// Remaining GraphQL points (of 5,000/hour) below which a refresh warns.
    static let lowRateLimit = 500

    func graphql<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        var req = request(api.appendingPathComponent("graphql"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await send(req)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let res = try decoder.decode(GQLResponse<T>.self, from: data)
        if let d = res.data { return d }
        throw GitHubError.graphql(res.errors?.map(\.message).joined(separator: "; ") ?? "empty response")
    }

    // MARK: - REST (context for prompts)

    /// Raw log of a GitHub Actions job (check run id == job id). Nil for non-Actions checks.
    public func jobLog(_ repo: RepoRef, jobID: Int) async -> String? {
        let url = api.appendingPathComponent("repos/\(repo.fullName)/actions/jobs/\(jobID)/logs")
        guard let data = try? await send(request(url)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Title/summary/text a check run published (works for third-party checks too).
    public func checkRunOutput(_ repo: RepoRef, id: Int) async -> String? {
        struct CheckRun: Decodable {
            struct Output: Decodable {
                let title: String?
                let summary: String?
                let text: String?
            }
            let output: Output
        }
        let url = api.appendingPathComponent("repos/\(repo.fullName)/check-runs/\(id)")
        guard let data = try? await send(request(url)), let r = try? JSONDecoder().decode(CheckRun.self, from: data)
        else {
            return nil
        }
        let parts = [r.output.title, r.output.summary, r.output.text].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    public func diff(_ repo: RepoRef, number: Int) async -> String? {
        var req = request(api.appendingPathComponent("repos/\(repo.fullName)/pulls/\(number)"))
        req.setValue("application/vnd.github.diff", forHTTPHeaderField: "Accept")
        guard let data = try? await send(req) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Plumbing

    func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 30
        return req
    }

    func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GitHubError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    static let prQuery = """
        query($owner: String!, $name: String!) {
          rateLimit { remaining resetAt }
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
              totalCount
              nodes {
                number title url isDraft updatedAt mergeable reviewDecision headRefName
                author { login __typename avatarUrl(size: 64) }
                commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 100) { totalCount nodes {
                  __typename
                  ... on CheckRun { name conclusion status detailsUrl databaseId title }
                  ... on StatusContext { context state targetUrl description }
                } } } } } }
                reviewThreads(last: 50) { totalCount nodes {
                  isResolved isOutdated path line
                  comments(first: 1) { totalCount nodes { author { login __typename } body url createdAt } }
                } }
                comments(last: 20) { nodes { author { login __typename } body url createdAt } }
              }
            }
          }
        }
        """
}

// MARK: - GraphQL decoding

struct GQLResponse<T: Decodable>: Decodable {
    struct GQLError: Decodable { let message: String }
    let data: T?
    let errors: [GQLError]?
}

struct Conn<T: Decodable>: Decodable { let nodes: [T] }
/// A connection that also reports its size, so a capped `first:`/`last:` can say what it left out.
struct CountedConn<T: Decodable>: Decodable {
    let totalCount: Int
    let nodes: [T]
}

struct ActorNode: Decodable {
    let login: String
    let typename: String?
    let avatarUrl: URL?  // only requested for PR authors
    enum CodingKeys: String, CodingKey { case login, typename = "__typename", avatarUrl }
    var isBot: Bool { typename == "Bot" || login.hasSuffix("[bot]") }
}

struct CommentNode: Decodable {
    let author: ActorNode?
    let body: String
    let url: URL
    let createdAt: Date

    var model: CommentInfo {
        CommentInfo(
            author: author?.login ?? "ghost", isBot: author?.isBot ?? false, body: body, url: url, createdAt: createdAt)
    }
}

struct ContextNode: Decodable {
    let typename: String
    let name: String?, conclusion: String?, status: String?, detailsUrl: URL?, databaseId: Int?, title: String?
    let context: String?, state: String?, targetUrl: URL?, description: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", name, conclusion, status, detailsUrl, databaseId, title
        case context, state, targetUrl, description
    }

    var model: CheckInfo {
        if typename == "CheckRun" {
            let s: CheckState
            if status != "COMPLETED" {
                s = .pending
            } else {
                switch conclusion {
                case "SUCCESS": s = .success
                case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": s = .failure
                default: s = .neutral  // SKIPPED, NEUTRAL, CANCELLED, STALE
                }
            }
            return CheckInfo(name: name ?? "check", state: s, url: detailsUrl, checkRunID: databaseId, summary: title)
        }
        let s: CheckState =
            switch state {
            case "SUCCESS": .success
            case "FAILURE", "ERROR": .failure
            case "PENDING", "EXPECTED": .pending
            default: .neutral
            }
        return CheckInfo(name: context ?? "status", state: s, url: targetUrl, summary: description)
    }
}

struct RepoData: Decodable {
    struct Repo: Decodable { let pullRequests: CountedConn<PRNode> }
    struct RateLimit: Decodable {
        let remaining: Int
        let resetAt: Date
    }
    let rateLimit: RateLimit?
    let repository: Repo?
}

struct PRNode: Decodable {
    struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let contexts: CountedConn<ContextNode> }
            let oid: String
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }
    struct ThreadNode: Decodable {
        struct Comments: Decodable { let totalCount: Int; let nodes: [CommentNode] }
        let isResolved: Bool, isOutdated: Bool, path: String?, line: Int?
        let comments: Comments
    }

    let number: Int, title: String, url: URL, isDraft: Bool, updatedAt: Date
    let mergeable: String, reviewDecision: String?, headRefName: String
    let author: ActorNode?
    let commits: Conn<CommitNode>
    let reviewThreads: CountedConn<ThreadNode>
    let comments: Conn<CommentNode>

    func truncationWarnings(repo: RepoRef) -> [String] {
        var w: [String] = []
        if let checks = commits.nodes.last?.commit.statusCheckRollup?.contexts, checks.totalCount > checks.nodes.count {
            w.append("\(repo.name)#\(number): read the first \(checks.nodes.count) of \(checks.totalCount) checks")
        }
        if reviewThreads.totalCount > reviewThreads.nodes.count {
            let (read, total) = (reviewThreads.nodes.count, reviewThreads.totalCount)
            w.append("\(repo.name)#\(number): read the newest \(read) of \(total) review threads")
        }
        return w
    }

    func toModel(repo: RepoRef) -> PullRequest {
        let head = commits.nodes.last?.commit
        let threads: [ReviewThreadInfo] = reviewThreads.nodes.compactMap { t in
            guard let first = t.comments.nodes.first else { return nil }
            return ReviewThreadInfo(
                isResolved: t.isResolved, isOutdated: t.isOutdated, path: t.path, line: t.line,
                firstComment: first.model, commentCount: t.comments.totalCount)
        }
        return PullRequest(
            repo: repo, number: number, title: title, url: url, author: author?.login ?? "ghost",
            authorAvatar: author?.avatarUrl,
            isDraft: isDraft, updatedAt: updatedAt, headSha: head?.oid ?? "", headRef: headRefName,
            mergeable: Mergeable(rawValue: mergeable) ?? .unknown,
            reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)) ?? .none,
            checks: head?.statusCheckRollup?.contexts.nodes.map(\.model) ?? [],
            threads: threads,
            comments: comments.nodes.map(\.model)
        )
    }
}
