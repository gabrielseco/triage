import Testing

@testable import TriageCore

private let repo = RepoRef(owner: "remoteoss", name: "remote-flows")

@Test func worktreeSitsNextToTheCheckout() {
    #expect(
        Handoff.worktreePath(checkout: "/Users/g/remote/remote-flows", pr: 1392)
            == "/Users/g/remote/remote-flows-pr-1392")
    #expect(
        Handoff.worktreePath(checkout: "/Users/g/remote/remote-flows/", pr: 7) == "/Users/g/remote/remote-flows-pr-7")
}

@Test func shellQuoteSurvivesQuotesAndSpaces() {
    #expect(Handoff.shellQuote("a b") == "'a b'")
    #expect(Handoff.shellQuote("it's") == #"'it'\''s'"#)
}

@Test func originMatchingIgnoresProtocolAndSuffix() {
    #expect(Handoff.originMatches("git@github.com:remoteoss/remote-flows.git", repo))
    #expect(Handoff.originMatches("https://github.com/RemoteOSS/remote-flows", repo))
    #expect(!Handoff.originMatches("git@github.com:remoteoss/remote-flows-legacy.git", repo))
}

@Test func scriptSubstitutesThePromptFileAndQuotesValues() {
    let plan = HandoffPlan(
        repo: repo, prNumber: 1392, branch: "renovate/jsdom-30.x", checkout: "/Users/g/remote/remote-flows",
        promptFile: "/tmp/p.md", harnessCommand: Handoff.defaultHarnessCommand)
    let s = Handoff.script(plan)
    #expect(s.hasPrefix("#!/bin/zsh -il"))
    #expect(s.contains(#"claude "$(cat "$PROMPT_FILE")""#))
    #expect(s.contains("BRANCH='renovate/jsdom-30.x'"))
    #expect(s.contains("WT='/Users/g/remote/remote-flows-pr-1392'"))
    #expect(s.contains("gh pr checkout 1392"))
}

@Test func keyReferenceRejectsNonExecutablePaths() async {
    await #expect(throws: OnePasswordError.self) { try await KeyReference.read("/definitely/not/here.sh") }
    await #expect(throws: OnePasswordError.self) { try await KeyReference.read("") }
}
