import Foundation
import Testing

@testable import TriageCore

@Test func repoLinksPointAtGitHub() {
    let r = RepoRef(owner: "acme", name: "web")
    #expect(r.url.absoluteString == "https://github.com/acme/web")
    #expect(r.pullsURL.absoluteString == "https://github.com/acme/web/pulls")
}
