import Foundation

/// Where pull requests come from. GitLab is being added in steps (docs/plans/GITLAB.md).
public enum Forge: Hashable, Sendable {
    case github
    /// A GitLab instance by host, e.g. `gitlab.com`.
    case gitlab(host: String)

    public var name: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }

    /// How a PR number is written: `#12` on GitHub, `!12` for a GitLab merge request.
    public var numberPrefix: String {
        switch self {
        case .github: "#"
        case .gitlab: "!"
        }
    }

    /// What the forge calls a pull request, for labels.
    public var pullRequestsName: String {
        switch self {
        case .github: "Pull requests"
        case .gitlab: "Merge requests"
        }
    }

    /// The CLI command that shows a PR, for prompts: `gh pr view 12`, `glab mr view 12`.
    public func cli(_ verb: String, _ number: Int) -> String {
        switch self {
        case .github: "gh pr \(verb) \(number)"
        case .gitlab: "glab mr \(verb) \(number)"
        }
    }

    /// What Triage can do with this forge's pull requests; views hide what's missing.
    public var capabilities: ForgeCapabilities {
        switch self {
        case .github: .all
        // Each GitLab capability is turned on as it's built.
        case .gitlab: []
        }
    }
}

public struct ForgeCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// CI logs in fix prompts.
    public static let ciLogs = Self(rawValue: 1 << 0)
    /// The diff in prompts and Explain PR.
    public static let diff = Self(rawValue: 1 << 1)
    /// Handoff checks the branch out into a worktree.
    public static let checkout = Self(rawValue: 1 << 2)
    public static let approve = Self(rawValue: 1 << 3)
    public static let merge = Self(rawValue: 1 << 4)
    public static let close = Self(rawValue: 1 << 5)

    public static let all: Self = [.ciLogs, .diff, .checkout, .approve, .merge, .close]
}

/// One forge's API, as the app uses it. Everything above it sees only `PullRequest` and `RepoSnapshot`.
public protocol ForgeClient: Sendable {
    var forge: Forge { get }

    /// The signed-in user's login, for "Mine" and whose comments are new.
    func viewer() async throws -> String
    /// Every watched source's open pull requests. One repo failing doesn't lose the others; it throws only when
    /// nothing could be read (a bad token, the instance unreachable).
    func fetch() async throws -> [RepoResult]

    /// The log or output of a failed check, for the fix prompt. Nil if there's none to read.
    func ciLog(_ pr: PullRequest, checkRunID: Int) async -> String?
    func diff(_ pr: PullRequest) async -> String?

    /// Approves as the viewer, pinned to `pr.headSha`.
    func approve(_ pr: PullRequest) async throws
    /// Merges with `pr.mergeMethod`, only if the head is still `pr.headSha`.
    func merge(_ pr: PullRequest) async throws
    /// Closes without merging.
    func close(_ pr: PullRequest) async throws
}

/// One repo's fetch, tagged so results for a repo removed mid-fetch can be dropped.
public struct RepoResult: Sendable {
    public let repo: RepoRef
    public let result: Result<RepoSnapshot, Error>

    public init(repo: RepoRef, result: Result<RepoSnapshot, Error>) {
        self.repo = repo
        self.result = result
    }

    /// All repos in parallel, each failure tagged with its repo.
    static func fetchAll(
        _ repos: [RepoRef], _ fetch: @escaping @Sendable (RepoRef) async throws -> RepoSnapshot
    ) async -> [RepoResult] {
        await withTaskGroup(of: RepoResult.self) { group in
            for repo in repos {
                group.addTask {
                    do { return RepoResult(repo: repo, result: .success(try await fetch(repo))) } catch {
                        return RepoResult(
                            repo: repo, result: .failure(RepoError(repo: repo.fullName, underlying: error)))
                    }
                }
            }
            var results: [RepoResult] = []
            for await r in group { results.append(r) }
            return results
        }
    }
}

public enum ForgeError: LocalizedError {
    /// A forge Triage can't talk to yet.
    case unsupported(Forge)

    public var errorDescription: String? {
        switch self {
        case .unsupported(.github): "GitHub isn't supported yet."
        case .unsupported(.gitlab(let host)): "GitLab (\(host)) isn't supported yet."
        }
    }
}

public struct RepoError: LocalizedError {
    public let repo: String
    public let underlying: Error
    public var errorDescription: String? { "\(repo): \(underlying.localizedDescription)" }
}

/// GitHub behind `ForgeClient`: one GraphQL query per watched repo, REST for logs, the diff and actions.
public struct GitHubForge: ForgeClient {
    let client: GitHubClient
    let repos: [RepoRef]

    public var forge: Forge { .github }

    /// `repos` is what `fetch()` reads; the other calls don't need it.
    public init(token: String, repos: [RepoRef] = []) {
        client = GitHubClient(token: token)
        self.repos = repos
    }

    public func viewer() async throws -> String { try await client.viewerLogin() }

    public func fetch() async -> [RepoResult] {
        let client = client
        return await RepoResult.fetchAll(repos) { try await client.openPullRequests($0) }
    }

    /// The Actions job log (check run id == job id), else what a third-party check published.
    public func ciLog(_ pr: PullRequest, checkRunID: Int) async -> String? {
        if let log = await client.jobLog(pr.repo, jobID: checkRunID) { return log }
        return await client.checkRunOutput(pr.repo, id: checkRunID)
    }

    public func diff(_ pr: PullRequest) async -> String? { await client.diff(pr.repo, number: pr.number) }

    public func approve(_ pr: PullRequest) async throws {
        try await client.approvePullRequest(pr.repo, number: pr.number, sha: pr.headSha)
    }

    public func merge(_ pr: PullRequest) async throws {
        try await client.mergePullRequest(pr.repo, number: pr.number, sha: pr.headSha, method: pr.mergeMethod)
    }

    public func close(_ pr: PullRequest) async throws {
        try await client.closePullRequest(pr.repo, number: pr.number)
    }
}

/// GitLab behind `ForgeClient`, read-only for now: the merge requests assigned to the viewer or waiting on
/// their review, across projects. Actions throw until their capability is turned on.
public struct GitLabForge: ForgeClient {
    let client: GitLabClient

    public var forge: Forge { .gitlab(host: client.host) }

    public init(host: String, token: String) { client = GitLabClient(host: host, token: token) }

    public func viewer() async throws -> String { try await client.viewerUsername() }

    public func fetch() async throws -> [RepoResult] { Self.results(try await client.mergeRequests()) }

    /// One result per project, so projects behave like watched repos (new-PR clocks, the sidebar). Warnings
    /// aren't per project, so they ride on the first one; they're merged and sorted with the rest anyway.
    static func results(_ snapshot: RepoSnapshot) -> [RepoResult] {
        let byRepo = Dictionary(grouping: snapshot.pullRequests, by: \.repo)
        return byRepo.keys.sorted { $0.id < $1.id }.enumerated().map { i, repo in
            RepoResult(
                repo: repo,
                result: .success(
                    RepoSnapshot(pullRequests: byRepo[repo] ?? [], warnings: i == 0 ? snapshot.warnings : [])))
        }
    }

    public func ciLog(_ pr: PullRequest, checkRunID: Int) async -> String? { nil }
    public func diff(_ pr: PullRequest) async -> String? { nil }
    public func approve(_ pr: PullRequest) async throws { throw ForgeError.unsupported(forge) }
    public func merge(_ pr: PullRequest) async throws { throw ForgeError.unsupported(forge) }
    public func close(_ pr: PullRequest) async throws { throw ForgeError.unsupported(forge) }
}
