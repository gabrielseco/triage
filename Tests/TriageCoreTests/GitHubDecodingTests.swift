import Foundation
import Testing

@testable import TriageCore

private let repo = RepoRef(owner: "o", name: "r")

/// A response where every capped connection left something out.
private let truncated = Data(
    """
    {"data": {
      "rateLimit": {"remaining": 4000, "resetAt": "2026-09-26T12:00:00Z"},
      "repository": {"pullRequests": {"totalCount": 42, "nodes": [{
        "number": 7, "title": "t", "url": "https://github.com/o/r/pull/7", "isDraft": false,
        "createdAt": "2026-09-25T10:00:00Z", "updatedAt": "2026-09-26T10:00:00Z",
        "mergeable": "MERGEABLE", "reviewDecision": null, "headRefName": "b",
        "author": {"login": "me", "__typename": "User", "avatarUrl": null},
        "commits": {"nodes": [{"commit": {"oid": "abc", "statusCheckRollup": {"contexts": {"totalCount": 130,
          "nodes": [{"__typename": "CheckRun", "name": "ci", "conclusion": "FAILURE", "status": "COMPLETED",
                     "detailsUrl": null, "databaseId": 1, "title": null}]}}}}]},
        "reviewThreads": {"totalCount": 80, "nodes": []},
        "comments": {"nodes": []}
      }]}}
    }}
    """.utf8)

private func decode(_ data: Data) throws -> RepoData {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try #require(try decoder.decode(GQLResponse<RepoData>.self, from: data).data)
}

@Test func cappedConnectionsProduceWarnings() throws {
    let d = try decode(truncated)
    let pr = try #require(d.repository?.pullRequests.nodes.first)
    #expect(d.repository?.pullRequests.totalCount == 42)
    #expect(
        pr.truncationWarnings(repo: repo) == [
            "o/r#7: read the first 1 of 130 checks",
            "o/r#7: read the newest 0 of 80 review threads",
        ])
    #expect(pr.toModel(repo: repo).checks.map(\.state) == [.failure])
}

@Test func completeConnectionsProduceNoWarnings() throws {
    let complete = String(decoding: truncated, as: UTF8.self)
        .replacingOccurrences(of: #""totalCount": 130"#, with: #""totalCount": 1"#)
        .replacingOccurrences(of: #""totalCount": 80"#, with: #""totalCount": 0"#)
    let pr = try #require(try decode(Data(complete.utf8)).repository?.pullRequests.nodes.first)
    #expect(pr.truncationWarnings(repo: repo).isEmpty)
}

/// A trimmed real-shaped response for the PR query, decoded exactly as GitHubClient does.
private let fixture = """
    {"repository": {"pullRequests": {"totalCount": 1, "nodes": [{
      "number": 1392, "title": "chore(deps-dev): update dependency jsdom to v30.1.0",
      "url": "https://github.com/remoteoss/remote-flows/pull/1392", "isDraft": false,
      "createdAt": "2026-09-23T10:00:00Z", "updatedAt": "2026-09-24T10:00:00Z",
      "mergeable": "CONFLICTING", "reviewDecision": null,
      "headRefName": "renovate/jsdom-30.x",
      "author": {"login": "renovate", "__typename": "Bot", "avatarUrl": "https://avatars.githubusercontent.com/in/2740"},
      "commits": {"nodes": [{"commit": {"oid": "abc123", "statusCheckRollup": {"contexts": {"totalCount": 4, "nodes": [
        {"__typename": "CheckRun", "name": "Tests with Coverage", "conclusion": "FAILURE", "status": "COMPLETED",
         "detailsUrl": "https://github.com/x/y/actions/runs/1/job/9", "databaseId": 9, "title": "2 failed"},
        {"__typename": "CheckRun", "name": "lint", "conclusion": null, "status": "IN_PROGRESS",
         "detailsUrl": null, "databaseId": 10, "title": null},
        {"__typename": "CheckRun", "name": "e2e", "conclusion": "SKIPPED", "status": "COMPLETED",
         "detailsUrl": null, "databaseId": 11, "title": null},
        {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR",
         "targetUrl": "https://ci.example.com/1", "description": "boom"}
      ]}}}}]},
      "reviewThreads": {"totalCount": 2, "nodes": [
        {"isResolved": false, "isOutdated": false, "path": "src/a.ts", "line": 12,
         "comments": {"totalCount": 3, "nodes": [{"author": {"login": "alice", "__typename": "User"},
           "body": "why?", "url": "https://github.com/x/y/pull/1#r1", "createdAt": "2026-09-24T09:00:00Z"}]}},
        {"isResolved": false, "isOutdated": false, "path": null, "line": null,
         "comments": {"totalCount": 0, "nodes": []}}
      ]},
      "comments": {"nodes": [
        {"author": {"login": "cursor[bot]", "__typename": "Bot"}, "body": "### Bug\\n**High Severity**",
         "url": "https://github.com/x/y/pull/1#c1", "createdAt": "2026-09-24T08:00:00Z"},
        {"author": null, "body": "from a deleted account", "url": "https://github.com/x/y/pull/1#c2",
         "createdAt": "2026-09-24T07:00:00Z"}
      ]}
    }]}}}
    """

private func decodePR() throws -> PullRequest {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try decoder.decode(RepoData.self, from: Data(fixture.utf8))
    let node = try #require(data.repository?.pullRequests.nodes.first)
    return node.toModel(repo: RepoRef(owner: "remoteoss", name: "remote-flows"))
}

@Test func decodesPullRequestFields() throws {
    let pr = try decodePR()
    #expect(pr.id == "remoteoss/remote-flows#1392")
    #expect(pr.author == "renovate")
    #expect(pr.authorAvatar?.host == "avatars.githubusercontent.com")
    #expect(pr.headSha == "abc123")
    #expect(pr.createdAt == ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z"))
    #expect(pr.mergeable == .conflicting)
    #expect(pr.reviewDecision == .none)
}

@Test func mapsBothCheckSystemsToOneState() throws {
    let states = try decodePR().checks.map { "\($0.name)=\($0.state.rawValue)" }
    #expect(states == ["Tests with Coverage=failure", "lint=pending", "e2e=neutral", "ci/legacy=failure"])
    #expect(try decodePR().checks[0].checkRunID == 9)
}

@Test func keepsThreadsWithCommentsAndDetectsBots() throws {
    let pr = try decodePR()
    #expect(pr.threads.count == 1)  // the thread with no comments is dropped
    #expect(pr.threads[0].commentCount == 3)
    #expect(pr.comments.map(\.isBot) == [true, false])
    #expect(pr.comments[1].author == "ghost")
}

@Test func decodedPRClassifiesEndToEnd() throws {
    let kinds = Set(Classifier.classify(try decodePR()).items.map(\.kind))
    #expect(kinds == [.ciFailure, .mergeConflict, .reviewThreads, .botFinding])
}

@Test func decodesTheRateLimitAsData() throws {
    let snapshotLimit = try #require(try decode(truncated).rateLimit)
    #expect(snapshotLimit.remaining == 4000)
}

@Test func mergedReposWarnAboutTheRateLimitOnceWithTheLowestCount() {
    let reset = Date(timeIntervalSince1970: 0)
    let snapshots = [480, 448, 464].map {
        RepoSnapshot(pullRequests: [], warnings: ["r\($0): capped"], rateLimit: .init(remaining: $0, resetAt: reset))
    }
    let warnings = RepoSnapshot.merging(snapshots).allWarnings
    #expect(warnings.filter { $0.hasPrefix("GitHub API:") }.count == 1)
    #expect(warnings.last?.hasPrefix("GitHub API: 448 points left") == true)
    #expect(warnings.dropLast() == ["r448: capped", "r464: capped", "r480: capped"])  // all kept, in a stable order
}

@Test func plentyOfRateLimitLeftIsNotAWarning() {
    let snapshot = RepoSnapshot(pullRequests: [], rateLimit: .init(remaining: 4000, resetAt: Date()))
    #expect(RepoSnapshot.merging([snapshot, RepoSnapshot(pullRequests: [])]).allWarnings.isEmpty)
}

@Test func changesURLPointsAtTheDiff() throws {
    #expect(try decodePR().changesURL.absoluteString == "https://github.com/remoteoss/remote-flows/pull/1392/changes")
}
