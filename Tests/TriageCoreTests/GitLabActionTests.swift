import Foundation
import Testing

@testable import TriageCore

private func mr(sha: String = "abc123") throws -> PullRequest {
    PullRequest(
        repo: try #require(RepoRef(gitlabPath: "acme/platform/web", host: "gitlab.example.com")), number: 12,
        title: "Add export", url: URL(string: "https://gitlab.example.com/acme/platform/web/-/merge_requests/12")!,
        author: "rita", headSha: sha)
}

@Test func approvingPostsToTheProjectByItsEncodedPathPinnedToTheHead() throws {
    let req = try GitLabClient(host: "gitlab.example.com", token: "t").approveRequest(try mr())
    #expect(req.httpMethod == "POST")
    #expect(
        req.url?.absoluteString
            == "https://gitlab.example.com/api/v4/projects/acme%2Fplatform%2Fweb/merge_requests/12/approve")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    let body = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: String]
    #expect(body == ["sha": "abc123"])
}

@Test func mergingPutsToTheProjectPinnedToTheHeadWithTheSquashChoice() throws {
    let client = GitLabClient(host: "gitlab.example.com", token: "t")
    let req = try client.acceptRequest(try mr(sha: "def456"), method: .merge)
    #expect(req.httpMethod == "PUT")
    #expect(
        req.url?.absoluteString
            == "https://gitlab.example.com/api/v4/projects/acme%2Fplatform%2Fweb/merge_requests/12/merge")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any]
    #expect(body?["sha"] as? String == "def456")
    #expect(body?["squash"] as? Bool == false)

    let squash = try client.acceptRequest(try mr(), method: .squash)
    let squashBody = try JSONSerialization.jsonObject(with: try #require(squash.httpBody)) as? [String: Any]
    #expect(squashBody?["sha"] as? String == "abc123")
    #expect(squashBody?["squash"] as? Bool == true)
}

@Test func notBeingAllowedToMergeIsntABadToken() {
    let msg = GitLabError.cannotMerge.localizedDescription
    #expect(msg.contains("merge"))
    #expect(!msg.contains("token"))
}

@Test func aReadOnlyTokenSaysItNeedsTheApiScope() {
    let body =
        #"{"error":"insufficient_scope","error_description":"The request requires higher privileges","scope":"api"}"#
    #expect(GitLabError.http(403, body).localizedDescription.contains("api scope"))
    // Another 403 still shows GitLab's own message.
    #expect(
        GitLabError.http(403, #"{"message":"403 Forbidden"}"#).localizedDescription == "GitLab HTTP 403: 403 Forbidden")
}

@Test func notBeingAllowedToApproveIsntABadToken() {
    let msg = GitLabError.cannotApprove.localizedDescription
    #expect(msg.contains("approve"))
    #expect(!msg.contains("token"))
}
