import Foundation
import Testing

@testable import TriageCore

/// A trimmed real-shaped response for the PR query, decoded exactly as GitHubClient does.
private let fixture = """
    {"repository": {"pullRequests": {"nodes": [{
      "number": 1392, "title": "chore(deps-dev): update dependency jsdom to v30.1.0",
      "url": "https://github.com/remoteoss/remote-flows/pull/1392", "isDraft": false,
      "updatedAt": "2026-09-24T10:00:00Z", "mergeable": "CONFLICTING", "reviewDecision": null,
      "headRefName": "renovate/jsdom-30.x",
      "author": {"login": "renovate", "__typename": "Bot", "avatarUrl": "https://avatars.githubusercontent.com/in/2740"},
      "commits": {"nodes": [{"commit": {"oid": "abc123", "statusCheckRollup": {"contexts": {"nodes": [
        {"__typename": "CheckRun", "name": "Tests with Coverage", "conclusion": "FAILURE", "status": "COMPLETED",
         "detailsUrl": "https://github.com/x/y/actions/runs/1/job/9", "databaseId": 9, "title": "2 failed"},
        {"__typename": "CheckRun", "name": "lint", "conclusion": null, "status": "IN_PROGRESS",
         "detailsUrl": null, "databaseId": 10, "title": null},
        {"__typename": "CheckRun", "name": "e2e", "conclusion": "SKIPPED", "status": "COMPLETED",
         "detailsUrl": null, "databaseId": 11, "title": null},
        {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR",
         "targetUrl": "https://ci.example.com/1", "description": "boom"}
      ]}}}}]},
      "reviewThreads": {"nodes": [
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
