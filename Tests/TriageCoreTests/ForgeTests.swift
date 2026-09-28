import Foundation
import Testing

@testable import TriageCore

@Test func githubCanDoEverything() {
    #expect(Forge.github.capabilities == .all)
    #expect(GitHubForge(token: "t").forge == .github)
}

/// Dismissals and snoozes are keyed by ids built from the repo; the forge must not change them.
@Test func githubReposKeepTheirIds() throws {
    let r = RepoRef(owner: "acme", name: "web")
    #expect(r.forge == .github)
    #expect(r.id == "acme/web")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(String(decoding: try encoder.encode(r), as: UTF8.self) == #"{"name":"web","owner":"acme"}"#)
    #expect(try JSONDecoder().decode(RepoRef.self, from: Data(#"{"owner":"acme","name":"web"}"#.utf8)) == r)
}

@Test func gitlabCanDoNothingYet() {
    #expect(Forge.gitlab(host: "gitlab.com").capabilities.isEmpty)
    #expect(ForgeError.unsupported(.gitlab(host: "gitlab.com")).localizedDescription.contains("gitlab.com"))
}

@Test func gitlabProjectsNestAndLeadWithTheHost() throws {
    let r = try #require(RepoRef(gitlabPath: "acme/platform/web", host: "gitlab.com"))
    #expect(r.forge == .gitlab(host: "gitlab.com"))
    #expect(r.owner == "acme/platform")
    #expect(r.name == "web")
    #expect(r.fullName == "acme/platform/web")
    #expect(r.id == "gitlab.com/acme/platform/web")
    #expect(r.url.absoluteString == "https://gitlab.com/acme/platform/web")
    #expect(r.pullsURL.absoluteString == "https://gitlab.com/acme/platform/web/-/merge_requests")
    #expect(RepoRef(gitlabPath: "web", host: "gitlab.com") == nil)
    #expect(RepoRef(gitlabPath: "/web", host: "gitlab.com") == nil)
    for bad in ["gitlab.acme .com", "https://gitlab.com", "gitlab.com/x", ""] {
        #expect(RepoRef(gitlabPath: "acme/web", host: bad) == nil, "host \(bad)")
    }
}

/// A GitHub repo and a GitLab project with the same path are different repos, with different item ids.
@Test func sameNameOnBothForgesDoesntCollide() throws {
    let gh = RepoRef(owner: "acme", name: "web")
    let gl = try #require(RepoRef(gitlabPath: "acme/web", host: "gitlab.com"))
    #expect(gh != gl)
    #expect(gh.id != gl.id)
    let pr = { (repo: RepoRef) in
        PullRequest(repo: repo, number: 1, title: "t", url: repo.url, author: "a", headSha: "s")
    }
    #expect(pr(gh).id == "acme/web#1")
    #expect(pr(gl).id == "gitlab.com/acme/web#1")
}

@Test func gitlabReposRoundTripThroughJSON() throws {
    let r = try #require(RepoRef(gitlabPath: "acme/platform/web", host: "gitlab.example.com"))
    let back = try JSONDecoder().decode(RepoRef.self, from: try JSONEncoder().encode(r))
    #expect(back == r)
    #expect(back.id == "gitlab.example.com/acme/platform/web")
}

@Test func seenPRsKeepGitHubAndGitLabApart() throws {
    let gh = RepoRef(owner: "acme", name: "web")
    let gl = try #require(RepoRef(gitlabPath: "acme/web", host: "gitlab.com"))
    var seen = SeenPRs()
    seen.startWatching([gh], now: Date(timeIntervalSince1970: 0))
    #expect(Set(seen.repos.keys) == ["acme/web"])
    let fresh = PullRequest(
        repo: gl, number: 1, title: "t", url: gl.url, author: "a", createdAt: Date(timeIntervalSince1970: 10),
        headSha: "s")
    #expect(seen.isNew(fresh) == false)  // its project isn't watched yet
    seen.startWatching([gl], now: Date(timeIntervalSince1970: 5))
    #expect(seen.isNew(fresh))
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
