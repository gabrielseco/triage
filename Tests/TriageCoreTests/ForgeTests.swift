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

@Test func gitlabCanApproveButNothingElseYet() {
    #expect(Forge.gitlab(host: "gitlab.com").capabilities == [.approve])
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

private func mr(_ path: String, _ number: Int, host: String = "gitlab.com") throws -> PullRequest {
    let repo = try #require(RepoRef(gitlabPath: path, host: host))
    return PullRequest(
        repo: repo, number: number, title: "t",
        url: repo.url.appendingPathComponent("-/merge_requests/\(number)"), author: "a", headSha: "s",
        mergeable: .unknown)
}

@Test func gitlabMergeRequestsReadLikeGitLab() throws {
    let pr = try mr("acme/web", 12)
    #expect(pr.ref == "!12")
    #expect(pr.changesURL.absoluteString == "https://gitlab.com/acme/web/-/merge_requests/12/diffs")
    #expect(pr.checksURL.absoluteString == "https://gitlab.com/acme/web/-/merge_requests/12/pipelines")
    #expect(pr.mergeWarnings.contains("GitLab is still checking mergeability"))
    #expect(Forge.gitlab(host: "gitlab.com").cli("checkout", 12) == "glab mr checkout 12")
    #expect(Forge.gitlab(host: "gitlab.com").pullRequestsName == "Merge requests")

    let gh = PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: 7, title: "t",
        url: try #require(URL(string: "https://github.com/acme/web/pull/7")), author: "a", headSha: "s")
    #expect(gh.ref == "#7")
    #expect(gh.changesURL.absoluteString.hasSuffix("/pull/7/changes"))
    #expect(Forge.github.cli("view", 7) == "gh pr view 7")
}

@Test func gitlabPromptsUseGlab() throws {
    let pr = try mr("acme/web", 12)
    let item = AttentionItem(id: "x", kind: .ciFailure, severity: .high, pr: pr, headline: "h", evidence: [])
    let prompt = PromptBuilder.prompt(for: item, context: PromptContext(), mode: .claudeCode)
    #expect(prompt.contains("PR !12 in acme/web"))
    #expect(prompt.contains("`glab mr checkout 12`"))
    #expect(!prompt.contains("gh pr"))
    let explain = PromptBuilder.explainPRPrompt(for: pr, diff: nil, inWorktree: true)
    #expect(explain.contains("`glab mr view 12`"))
}

@Test func gitlabResultsGroupByProjectWithWarningsOnce() throws {
    let snap = RepoSnapshot(
        pullRequests: [try mr("acme/web", 1), try mr("acme/api", 2), try mr("acme/web", 3)],
        warnings: ["GitLab: capped"])
    let results = GitLabForge.results(snap)
    #expect(results.map(\.repo.id) == ["gitlab.com/acme/api", "gitlab.com/acme/web"])
    let snaps = try results.map { try $0.result.get() }
    #expect(snaps.map { $0.pullRequests.map(\.number) } == [[2], [1, 3]])
    #expect(snaps.flatMap(\.warnings) == ["GitLab: capped"])
    #expect(GitLabForge.results(RepoSnapshot(pullRequests: [])).isEmpty)
}

@Test func gitlabActionsOtherThanApproveAreNotSupportedYet() async throws {
    let forge = GitLabForge(host: "gitlab.com", token: "t")
    let pr = try mr("acme/web", 1)
    #expect(forge.forge == .gitlab(host: "gitlab.com"))
    await #expect(throws: ForgeError.self) { try await forge.merge(pr) }
    await #expect(throws: ForgeError.self) { try await forge.close(pr) }
    #expect(await forge.diff(pr) == nil)
    #expect(await forge.ciLog(pr, checkRunID: 1) == nil)
    #expect(GitLabError.noToken.localizedDescription.contains("Settings"))
}
