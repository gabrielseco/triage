import Foundation
import Testing

@testable import TriageCore

@Test func closingAPullRequestPatchesItsStateOnly() throws {
    let req = try GitHubClient(token: "t").closeRequest(RepoRef(owner: "acme", name: "web"), number: 1020)
    #expect(req.httpMethod == "PATCH")
    #expect(req.url?.absoluteString == "https://api.github.com/repos/acme/web/pulls/1020")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    let body = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: String]
    #expect(body == ["state": "closed"])
}

@Test func mergingPinsTheHeadAndUsesTheMethod() throws {
    let req = try GitHubClient(token: "t").mergeRequest(
        RepoRef(owner: "acme", name: "web"), number: 1020, sha: "abc123", method: .squash)
    #expect(req.httpMethod == "PUT")
    #expect(req.url?.absoluteString == "https://api.github.com/repos/acme/web/pulls/1020/merge")
    let body = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: String]
    #expect(body == ["sha": "abc123", "merge_method": "squash"])
}

@Test func httpErrorsShowGitHubsMessage() {
    let json = GitHubError.http(405, #"{"message": "Pull Request is not mergeable", "documentation_url": "x"}"#)
    #expect(json.localizedDescription == "GitHub HTTP 405: Pull Request is not mergeable")
    let raw = GitHubError.http(502, "Bad gateway")
    #expect(raw.localizedDescription == "GitHub HTTP 502: Bad gateway")
}

@Test func approvingPostsAnApprovalPinnedToTheHead() throws {
    let req = try GitHubClient(token: "t").approveRequest(
        RepoRef(owner: "acme", name: "web"), number: 1020, sha: "abc123")
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.github.com/repos/acme/web/pulls/1020/reviews")
    let body = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: String]
    #expect(body == ["commit_id": "abc123", "event": "APPROVE"])
}
