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
        "updatedAt": "2026-09-26T10:00:00Z", "mergeable": "MERGEABLE", "reviewDecision": null, "headRefName": "b",
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
            "r#7: read the first 1 of 130 checks",
            "r#7: read the newest 0 of 80 review threads",
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
