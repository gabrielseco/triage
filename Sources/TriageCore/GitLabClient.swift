import Foundation

public enum GitLabError: LocalizedError {
    case http(Int, String)
    case graphql(String)

    public var errorDescription: String? {
        switch self {
        case .http(401, _): "GitLab rejected the token (expired or revoked?). Create a new one with read_api."
        case .http(let code, let body): "GitLab HTTP \(code): \(Self.message(in: body) ?? String(body.prefix(300)))"
        case .graphql(let msg): "GitLab GraphQL: \(msg)"
        }
    }

    /// The `message` (or `error`) of a REST error body.
    static func message(in body: String) -> String? {
        struct Body: Decodable {
            let message: String?
            let error: String?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: Data(body.utf8)) else { return nil }
        return b.message ?? b.error
    }
}

/// GitLab's API for the merge requests assigned to the viewer or waiting on their review, across all projects.
/// Read-only for now: actions arrive with the capabilities that allow them (docs/plans/GITLAB.md).
public struct GitLabClient: Sendable {
    let host: String
    let token: String

    public init(host: String, token: String) {
        self.host = host
        self.token = token
    }

    /// Open merge requests per refresh: a cheap list query for which ones, then one detail query each, because
    /// GitLab caps a query's complexity and nesting jobs and discussions for 50 MRs goes over it.
    public func mergeRequests() async throws -> RepoSnapshot {
        let list: ListData = try await graphql(Self.listQuery, variables: [:])
        let (refs, listWarnings) = list.refs()
        let details = await withTaskGroup(of: Result<Detail, Error>.self) { group in
            for ref in refs {
                group.addTask {
                    do { return .success(try await mergeRequest(ref)) } catch {
                        return .failure(RepoError(repo: "\(ref.projectPath)!\(ref.iid)", underlying: error))
                    }
                }
            }
            var results: [Result<Detail, Error>] = []
            for await r in group { results.append(r) }
            return results
        }
        return try Self.snapshot(details, warnings: listWarnings)
    }

    /// One MR's failure is a warning, not a lost refresh; all of them failing (a bad token, the complexity cap)
    /// is an error.
    static func snapshot(_ details: [Result<Detail, Error>], warnings: [String]) throws -> RepoSnapshot {
        let loaded = details.compactMap { try? $0.get() }
        let failures = details.compactMap { r -> Error? in
            guard case .failure(let e) = r else { return nil }
            return e
        }
        if loaded.isEmpty, let first = failures.first { throw first }
        let detailWarnings = loaded.flatMap(\.warnings) + failures.map(\.localizedDescription)
        return RepoSnapshot(pullRequests: loaded.map(\.pr), warnings: warnings + detailWarnings.sorted())
    }

    public func viewerUsername() async throws -> String {
        struct ViewerData: Decodable {
            struct User: Decodable { let username: String }
            let currentUser: User?
        }
        let data: ViewerData = try await graphql("query { currentUser { username } }", variables: [:])
        guard let user = data.currentUser else { throw GitLabError.graphql("not signed in") }
        return user.username
    }

    /// One merge request and what its capped connections left out.
    struct Detail: Sendable {
        let pr: PullRequest
        let warnings: [String]
    }

    func mergeRequest(_ ref: MRRef) async throws -> Detail {
        let d: DetailData = try await graphql(
            Self.detailQuery, variables: ["path": ref.projectPath, "iid": ref.iid])
        guard let mr = d.project?.mergeRequest, let repo = RepoRef(gitlabPath: ref.projectPath, host: host) else {
            throw GitLabError.graphql("merge request not found or not accessible")
        }
        return Detail(pr: mr.toModel(repo: repo), warnings: mr.truncationWarnings(repo: repo))
    }

    // MARK: - Plumbing

    func graphql<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        guard let url = URL(string: "https://\(host)/api/graphql") else { throw GitLabError.graphql("bad host") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GitLabError.http(code, String(decoding: data, as: UTF8.self)) }
        return try Self.decode(data)
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let res = try gitlabDecoder.decode(GQLResponse<T>.self, from: data)
        if let d = res.data { return d }
        throw GitLabError.graphql(res.errors?.map(\.message).joined(separator: "; ") ?? "empty response")
    }

    static let listQuery = """
        query {
          currentUser {
            assignedMergeRequests(state: opened, first: 50, sort: UPDATED_DESC) {
              pageInfo { hasNextPage } nodes { iid project { fullPath } }
            }
            reviewRequestedMergeRequests(state: opened, first: 50, sort: UPDATED_DESC) {
              pageInfo { hasNextPage } nodes { iid project { fullPath } }
            }
          }
        }
        """

    static let detailQuery = """
        query($path: ID!, $iid: String!) {
          project(fullPath: $path) {
            mergeRequest(iid: $iid) {
              iid title description webUrl draft createdAt updatedAt sourceBranch diffHeadSha
              detailedMergeStatus conflicts approved approvalsLeft
              author { username avatarUrl bot }
              approvedBy { nodes { username } }
              reviewers { nodes { username mergeRequestInteraction { reviewState } } }
              headPipeline { jobs(first: 100) { count nodes { id name status allowFailure webPath } } }
              discussions(first: 100) { pageInfo { hasNextPage } nodes {
                resolvable resolved
                notes(first: 30) { nodes {
                  body system url createdAt author { username bot } position { newPath newLine }
                } }
              } }
            }
          }
        }
        """
}

/// GitLab's `Time` is ISO 8601, with or without fractional seconds.
let gitlabDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
        let s = try decoder.singleValueContainer().decode(String.self)
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        guard let date = plain.date(from: s) ?? fractional.date(from: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date \(s)"))
        }
        return date
    }
    return d
}()

// MARK: - GraphQL decoding

struct MRRef: Hashable, Sendable {
    let projectPath: String
    let iid: String
}

struct ListData: Decodable {
    struct Page: Decodable {
        struct PageInfo: Decodable { let hasNextPage: Bool }
        struct Node: Decodable {
            struct Project: Decodable { let fullPath: String }
            let iid: String
            let project: Project
        }
        let pageInfo: PageInfo
        let nodes: [Node]
    }
    struct User: Decodable {
        let assignedMergeRequests: Page
        let reviewRequestedMergeRequests: Page
    }
    let currentUser: User?

    /// Assigned and review-requested, without duplicates (you can be both), plus what the page caps left out.
    func refs() -> ([MRRef], [String]) {
        guard let u = currentUser else { return ([], []) }
        var seen = Set<MRRef>()
        let refs = (u.assignedMergeRequests.nodes + u.reviewRequestedMergeRequests.nodes)
            .map { MRRef(projectPath: $0.project.fullPath, iid: $0.iid) }
            .filter { seen.insert($0).inserted }
        var warnings: [String] = []
        for (page, what) in [
            (u.assignedMergeRequests, "assigned to you"), (u.reviewRequestedMergeRequests, "to review"),
        ]
        where page.pageInfo.hasNextPage {
            warnings.append("GitLab: showing the \(page.nodes.count) most recently updated merge requests \(what)")
        }
        return (refs, warnings)
    }
}

struct DetailData: Decodable {
    struct Project: Decodable { let mergeRequest: MRNode? }
    let project: Project?
}

struct GLUser: Decodable {
    let username: String
    let avatarUrl: String?
    let bot: Bool?

    /// Flagged bots, plus project and group access-token users, which GitLab names `project_<id>_bot…`.
    var isBot: Bool {
        if bot == true { return true }
        return username.wholeMatch(of: /(project|group)_\d+_bot.*/) != nil
    }
}

struct MRNode: Decodable {
    struct Conn<T: Decodable>: Decodable { let nodes: [T] }
    struct Reviewer: Decodable {
        struct Interaction: Decodable { let reviewState: String? }
        let username: String
        let mergeRequestInteraction: Interaction?
    }
    struct Pipeline: Decodable {
        struct Jobs: Decodable {
            let count: Int
            let nodes: [Job]
        }
        let jobs: Jobs?
    }
    struct Job: Decodable {
        let id: String, name: String?, status: String?, allowFailure: Bool?, webPath: String?
    }
    struct Discussions: Decodable {
        struct PageInfo: Decodable { let hasNextPage: Bool }
        let pageInfo: PageInfo
        let nodes: [Discussion]
    }
    struct Discussion: Decodable {
        let resolvable: Bool, resolved: Bool
        let notes: Conn<Note>
    }
    struct Note: Decodable {
        struct Position: Decodable {
            let newPath: String?
            let newLine: Int?
        }
        let body: String, system: Bool, url: String?, createdAt: Date
        let author: GLUser?
        let position: Position?
    }

    let iid: String, title: String, description: String?, webUrl: URL, draft: Bool
    let createdAt: Date, updatedAt: Date, sourceBranch: String, diffHeadSha: String?
    let detailedMergeStatus: String?, conflicts: Bool?, approved: Bool?, approvalsLeft: Int?
    let author: GLUser?
    let approvedBy: Conn<GLUser>?
    let reviewers: Conn<Reviewer>?
    let headPipeline: Pipeline?
    let discussions: Discussions

    func toModel(repo: RepoRef) -> PullRequest {
        let hostURL = URL(string: "/", relativeTo: repo.url)?.absoluteURL ?? repo.url
        let approvers = Set(approvedBy?.nodes.map(\.username) ?? [])
        // System notes ("added 3 commits", "changed the title") aren't comments; left in, every push would read
        // as new discussion.
        let human = discussions.nodes.map { d in (d, d.notes.nodes.filter { !$0.system }) }.filter { !$0.1.isEmpty }
        let threads = human.filter { $0.0.resolvable }.map { d, notes in
            ReviewThreadInfo(
                // GitLab has no simple "outdated" flag; an unresolved thread stays open until someone resolves it.
                isResolved: d.resolved, isOutdated: false, path: notes[0].position?.newPath,
                line: notes[0].position?.newLine, firstComment: notes[0].model(hostURL),
                commentCount: notes.count, replies: notes.dropFirst().map { $0.model(hostURL) })
        }
        return PullRequest(
            repo: repo, number: Int(iid) ?? 0, title: title, url: webUrl, author: author?.username ?? "ghost",
            authorAvatar: author?.avatarUrl.flatMap { URL(string: $0, relativeTo: hostURL)?.absoluteURL },
            isDraft: draft, createdAt: createdAt, updatedAt: updatedAt, headSha: diffHeadSha ?? "",
            headRef: sourceBranch, mergeable: mergeable, reviewDecision: reviewDecision(approvers: approvers),
            approvedBy: approvers,
            checks: headPipeline?.jobs?.nodes.map { $0.model(hostURL) } ?? [],
            threads: threads,
            comments: human.filter { !$0.0.resolvable }.flatMap { $0.1.map { $0.model(hostURL) } },
            summary: PRSummary.extract(description))
    }

    func truncationWarnings(repo: RepoRef) -> [String] {
        var w: [String] = []
        if let jobs = headPipeline?.jobs, jobs.count > jobs.nodes.count {
            w.append("\(repo.fullName)!\(iid): read the first \(jobs.nodes.count) of \(jobs.count) jobs")
        }
        if discussions.pageInfo.hasNextPage {
            w.append("\(repo.fullName)!\(iid): read the first \(discussions.nodes.count) discussions")
        }
        return w
    }

    var mergeable: Mergeable {
        if conflicts == true { return .conflicting }
        switch detailedMergeStatus {
        case "CONFLICT", "NEED_REBASE": return .conflicting
        case "CHECKING", "UNCHECKED", "PREPARING", nil: return .unknown
        default: return .mergeable
        }
    }

    /// A reviewer asking for changes wins, as on GitHub. "Approved" needs a real approval: with no approval
    /// rules GitLab calls every MR approved, and that mustn't read as ready to merge.
    func reviewDecision(approvers: Set<String>) -> ReviewDecision {
        let states = reviewers?.nodes.compactMap(\.mergeRequestInteraction?.reviewState) ?? []
        if states.contains("REQUESTED_CHANGES") { return .changesRequested }
        if (approvalsLeft ?? 0) > 0 { return .reviewRequired }
        if approved == true, !approvers.isEmpty { return .approved }
        return .none
    }
}

extension MRNode.Job {
    func model(_ hostURL: URL) -> CheckInfo {
        let state: CheckState =
            switch status {
            case "SUCCESS": .success
            case "FAILED": allowFailure == true ? .neutral : .failure
            case "CREATED", "WAITING_FOR_RESOURCE", "PREPARING", "PENDING", "RUNNING", "SCHEDULED",
                "WAITING_FOR_CALLBACK":
                .pending
            default: .neutral  // CANCELED, CANCELING, SKIPPED, MANUAL
            }
        // "gid://gitlab/Ci::Build/123": the number is the job id, for its log.
        let jobID = id.split(separator: "/").last.flatMap { Int($0) }
        return CheckInfo(
            name: name ?? "job", state: state,
            url: webPath.flatMap { URL(string: $0, relativeTo: hostURL)?.absoluteURL }, checkRunID: jobID)
    }
}

extension MRNode.Note {
    func model(_ hostURL: URL) -> CommentInfo {
        CommentInfo(
            author: author?.username ?? "ghost", isBot: author?.isBot ?? false, body: body,
            url: url.flatMap { URL(string: $0, relativeTo: hostURL)?.absoluteURL }, createdAt: createdAt)
    }
}
