import Foundation
import Testing

@testable import TriageCore

@Test func githubCanDoEverything() {
    #expect(Forge.github.capabilities == .all)
    #expect(Forge.github.name == "GitHub")
    #expect(GitHubForge(token: "t").forge == .github)
}

/// Dismissals and snoozes are keyed by ids built from the repo; the forge must not change them.
@Test func githubReposKeepTheirIds() throws {
    let r = RepoRef(owner: "acme", name: "web")
    #expect(r.forge == .github)
    #expect(r.id == "acme/web")
    let json = try JSONEncoder().encode(r)
    #expect(String(decoding: json, as: UTF8.self).contains("forge") == false)
    #expect(try JSONDecoder().decode(RepoRef.self, from: Data(#"{"owner":"acme","name":"web"}"#.utf8)) == r)
}

struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

@Test func fetchAllKeepsOtherReposWhenOneFails() async {
    let ok = RepoRef(owner: "acme", name: "web")
    let bad = RepoRef(owner: "acme", name: "api")
    let results = await RepoResult.fetchAll([ok, bad]) { repo in
        if repo == bad { throw Boom() }
        return RepoSnapshot(pullRequests: [], warnings: ["w"])
    }
    #expect(results.count == 2)
    let byRepo = Dictionary(uniqueKeysWithValues: results.map { ($0.repo, $0.result) })
    #expect((try? byRepo[ok]?.get())?.warnings == ["w"])
    guard case .failure(let e)? = byRepo[bad] else {
        Issue.record("expected a failure for \(bad.fullName)")
        return
    }
    #expect(e.localizedDescription == "acme/api: boom")
}
