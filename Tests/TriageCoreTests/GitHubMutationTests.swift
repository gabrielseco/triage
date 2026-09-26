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
