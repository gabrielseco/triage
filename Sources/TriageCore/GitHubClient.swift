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
    public static func resolveToken() async -> String? {
        if let t = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !t.isEmpty { return t }
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: gh) {
            guard let out = try? await Subprocess.run(gh, ["auth", "token"]) else { continue }
            if out.status == 0, !out.trimmedStdout.isEmpty { return out.trimmedStdout }
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

    public func openPullRequests(_ repo: RepoRef) async throws -> [PullRequest] {
        let d: RepoData = try await graphql(Self.prQuery, variables: ["owner": repo.owner, "name": repo.name])
        guard let r = d.repository else {
            throw GitHubError.graphql("repository \(repo.fullName) not found or not accessible")
        }
        return r.pullRequests.nodes.map { $0.toModel(repo: repo) }
    }

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

    // MARK: - Mutations

    /// Closes the pull request without merging it (it can be reopened on GitHub).
    public func closePullRequest(_ repo: RepoRef, number: Int) async throws {
        _ = try await send(try closeRequest(repo, number: number))
    }

    func closeRequest(_ repo: RepoRef, number: Int) throws -> URLRequest {
        var req = request(api.appendingPathComponent("repos/\(repo.fullName)/pulls/\(number)"))
        req.httpMethod = "PATCH"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["state": "closed"])
        return req
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
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url isDraft updatedAt mergeable reviewDecision headRefName
                author { login __typename avatarUrl(size: 64) }
                commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 60) { nodes {
                  __typename
                  ... on CheckRun { name conclusion status detailsUrl databaseId title }
                  ... on StatusContext { context state targetUrl description }
                } } } } } }
                reviewThreads(first: 50) { nodes {
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
    struct Repo: Decodable { let pullRequests: Conn<PRNode> }
    let repository: Repo?
}

struct PRNode: Decodable {
    struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let contexts: Conn<ContextNode> }
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
    let reviewThreads: Conn<ThreadNode>
    let comments: Conn<CommentNode>

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
