import Foundation
import Testing

@testable import TriageCore

private let pr = PullRequest(
    repo: RepoRef(owner: "acme", name: "web"), number: 7, title: "Add retries",
    url: URL(string: "https://github.com/acme/web/pull/7")!, author: "alice", headSha: "abcdef1234567890",
    headRef: "feat/retries", summary: "Retries uploads **three** times.")

@Test func explainPRPromptCarriesThePRDescriptionAndDiff() {
    let p = PromptBuilder.explainPRPrompt(for: pr, diff: "+retry()", inWorktree: false)
    #expect(p.hasPrefix(#"Explain PR #7 in acme/web to me: "Add retries""#))
    #expect(p.contains("## Description (summary)\nRetries uploads **three** times."))
    #expect(p.contains("```diff\n+retry()\n```"))
    #expect(p.contains("Work from the description and diff above."))
    #expect(p.contains("Don't edit files, commit or push"))
}

@Test func explainPRPromptInAWorktreePointsAtTheCode() {
    let p = PromptBuilder.explainPRPrompt(for: pr, diff: nil, inWorktree: true)
    #expect(p.contains("You're in a git worktree on branch feat/retries"))
    #expect(p.contains("`gh pr view 7`"))
    #expect(!p.contains("## PR diff"))
}

@Test func explainPRPromptWithoutADescriptionSkipsTheSection() {
    var bare = pr
    bare.summary = nil
    #expect(!PromptBuilder.explainPRPrompt(for: bare, diff: nil, inWorktree: false).contains("## Description"))
}
