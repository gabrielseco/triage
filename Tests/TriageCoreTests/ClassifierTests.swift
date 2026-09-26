import Foundation
import Testing

@testable import TriageCore

private let repo = RepoRef(owner: "acme", name: "web")

private func pr(
    checks: [CheckInfo] = [], threads: [ReviewThreadInfo] = [], comments: [CommentInfo] = [],
    mergeable: Mergeable = .mergeable, review: ReviewDecision = .none, sha: String = "abc123",
    draft: Bool = false
) -> PullRequest {
    PullRequest(
        repo: repo, number: 1020, title: "Add thing", url: URL(string: "https://github.com/acme/web/pull/1020")!,
        author: "gabriel", isDraft: draft, headSha: sha, mergeable: mergeable, reviewDecision: review,
        checks: checks, threads: threads, comments: comments)
}

private func comment(_ author: String, bot: Bool, _ body: String = "hi", url: String? = nil) -> CommentInfo {
    CommentInfo(author: author, isBot: bot, body: body, url: url.flatMap(URL.init(string:)))
}

@Test func failingChecksCollapseIntoOneItem() {
    let (items, stats) = Classifier.classify(
        pr(checks: [
            CheckInfo(name: "lint", state: .failure, checkRunID: 1),
            CheckInfo(name: "test", state: .failure, checkRunID: 2),
            CheckInfo(name: "build", state: .pending),
            CheckInfo(name: "types", state: .success),
        ]))
    #expect(items.count == 1)
    #expect(items[0].kind == .ciFailure)
    #expect(items[0].severity == .high)
    #expect(items[0].evidence.map(\.checkRunID) == [1, 2])
    #expect(stats.pendingChecks == 1)
}

@Test func newPushChangesItemIdentity() {
    let failing = [CheckInfo(name: "test", state: .failure)]
    let a = Classifier.classify(pr(checks: failing, sha: "aaa")).items[0].id
    let b = Classifier.classify(pr(checks: failing, sha: "bbb")).items[0].id
    #expect(a != b)
}

@Test func noiseBotsAreMutedAndCounted() {
    let (items, stats) = Classifier.classify(
        pr(comments: [
            comment("codecov[bot]", bot: true, "Coverage 80%"),
            comment("vercel", bot: true, "Preview deployed"),
        ]))
    #expect(items.map(\.kind) == [.awaitingReview])  // no bot finding: the PR is just waiting
    #expect(stats.noiseComments == 2)
}

@Test func actionableBotCommentsGroupPerBotAndEscalateOnAlarmWords() {
    let (items, _) = Classifier.classify(
        pr(comments: [
            comment("snyk-bot", bot: true, "Found a critical vulnerability in lodash", url: "https://x/1"),
            comment("snyk-bot", bot: true, "Another note", url: "https://x/2"),
            comment("copilot-pull-request-reviewer[bot]", bot: true, "Consider renaming"),
        ]))
    #expect(items.count == 2)
    let snyk = items.first { $0.headline.contains("snyk") }!
    #expect(snyk.evidence.count == 2)
    #expect(snyk.severity == .medium)
    let copilot = items.first { $0.headline.contains("copilot") }!
    #expect(copilot.severity == .low)
}

@Test func explicitBotSeverityLabelsWin() {
    #expect(Classifier.botSeverity("### Schema pin\n\n**High Severity**") == .high)
    #expect(Classifier.botSeverity("**Medium Severity** some text") == .medium)
    #expect(Classifier.botSeverity("**Low Severity** this could error in theory") == .low)
    #expect(Classifier.botSeverity("nit: rename") == .low)
}

@Test func botFindingHeadlineUsesItsTitle() {
    let body =
        "### GBR schema pin exceeds latest version\n\n**Medium Severity**\n\n<!-- DESCRIPTION START -->The GBR..."
    let (items, _) = Classifier.classify(pr(comments: [comment("cursor", bot: true, body)]))
    #expect(items[0].headline == "cursor: GBR schema pin exceeds latest version")
    #expect(items[0].severity == .medium)
}

@Test func onlyOpenHumanThreadsNeedReply() {
    let (items, _) = Classifier.classify(
        pr(threads: [
            ReviewThreadInfo(
                isResolved: false, path: "a.ex", line: 3, firstComment: comment("alice", bot: false, "why?")),
            ReviewThreadInfo(isResolved: true, firstComment: comment("bob", bot: false)),
            ReviewThreadInfo(isResolved: false, isOutdated: true, firstComment: comment("carol", bot: false)),
        ]))
    #expect(items.count == 1)
    #expect(items[0].kind == .reviewThreads)
    #expect(items[0].headline == "alice left an unresolved comment")
    #expect(items[0].evidence[0].title == "alice on a.ex:3")
}

@Test func conflictAndChangesRequested() {
    let kinds = Set(Classifier.classify(pr(mergeable: .conflicting, review: .changesRequested)).items.map(\.kind))
    #expect(kinds == [.mergeConflict, .changesRequested])
}

@Test func readyToMergeOnlyWhenNothingElseIsOpen() {
    let green = [CheckInfo(name: "test", state: .success), CheckInfo(name: "skip", state: .neutral)]
    #expect(Classifier.classify(pr(checks: green, review: .approved)).items.map(\.kind) == [.readyToMerge])
    #expect(Classifier.classify(pr(checks: green, review: .approved, draft: true)).items.isEmpty)
    #expect(Classifier.classify(pr(checks: [], review: .approved)).items.isEmpty)
}

@Test func quietPRsWaitForReviewUnlessApprovedOrDraft() {
    let green = [CheckInfo(name: "ci", state: .success), CheckInfo(name: "e2e", state: .pending)]
    let waiting = Classifier.classify(pr(checks: green)).items
    #expect(waiting.map(\.kind) == [.awaitingReview])
    #expect(waiting[0].severity == .info)
    #expect(waiting[0].headline == "Waiting for review · 1 check running")
    let two = green + [CheckInfo(name: "lint", state: .pending)]
    #expect(Classifier.classify(pr(checks: two)).items[0].headline == "Waiting for review · 2 checks running")
    #expect(Classifier.classify(pr(checks: green, review: .reviewRequired)).items.map(\.kind) == [.awaitingReview])
    #expect(Classifier.classify(pr(checks: green, draft: true)).items.isEmpty)
    // Something wrong wins: the PR isn't just waiting.
    #expect(Classifier.classify(pr(checks: green, mergeable: .conflicting)).items.map(\.kind) == [.mergeConflict])
}

@Test func approvedPRsWaitOnCIUntilReady() {
    let running = [CheckInfo(name: "ci", state: .success), CheckInfo(name: "e2e", state: .pending)]
    let items = Classifier.classify(pr(checks: running, review: .approved)).items
    #expect(items.map(\.kind) == [.awaitingChecks])
    #expect(items[0].severity == .info)
    #expect(items[0].headline == "Approved · 1 check running")
    #expect(items[0].evidence.map(\.title) == ["e2e is running"])

    let green = [CheckInfo(name: "ci", state: .success)]
    let unknown = Classifier.classify(pr(checks: green, mergeable: .unknown, review: .approved)).items
    #expect(unknown.map(\.kind) == [.awaitingChecks])
    #expect(unknown[0].headline == "Approved · GitHub is still checking mergeability")

    #expect(Classifier.classify(pr(checks: green, review: .approved)).items.map(\.kind) == [.readyToMerge])
    #expect(Classifier.classify(pr(checks: running, review: .approved, draft: true)).items.isEmpty)
    let failing = running + [CheckInfo(name: "lint", state: .failure)]
    #expect(Classifier.classify(pr(checks: failing, review: .approved)).items.map(\.kind) == [.ciFailure])
}

@Test func repoRefParsesUrlsAndShorthand() {
    #expect(RepoRef(string: "acme/web") == repo)
    #expect(RepoRef(string: "https://github.com/acme/web.git") == repo)
    #expect(RepoRef(string: "nope") == nil)
}

@Test func promptIncludesTailOfLogsAndLabelsIt() {
    let item = Classifier.classify(pr(checks: [CheckInfo(name: "test", state: .failure, checkRunID: 7)])).items[0]
    let log = (1...400).map { "line \($0)" }.joined(separator: "\n")
    let p = PromptBuilder.prompt(
        for: item, context: PromptContext(checkOutputs: [("test", log)], diff: "+x"), mode: .claudeCode)
    #expect(p.contains("You're on PR #1020"))
    #expect(p.contains("last 250 of 400 lines"))
    #expect(p.contains("line 400"))
    #expect(!p.contains("line 150\n"))
    #expect(p.contains("gh pr checkout 1020"))
}

private func thread(
    _ n: Int, resolved: Bool = false, outdated: Bool = false, replies: [String] = [], bot: Bool = false
) -> ReviewThreadInfo {
    func at(_ author: String, _ i: Int, bot: Bool = false) -> CommentInfo {
        var c = comment(author, bot: bot, url: "https://github.com/acme/web/pull/1020#r\(n)-\(i)")
        // Replies come after every thread's first comment, as they do on GitHub.
        c.createdAt = Date(timeIntervalSince1970: TimeInterval((i == 0 ? 0 : 10_000) + n * 100 + i))
        return c
    }
    return ReviewThreadInfo(
        isResolved: resolved, isOutdated: outdated, firstComment: at(bot ? "bugbot" : "alice", 0, bot: bot),
        commentCount: 1 + replies.count,
        replies: replies.enumerated().map { at($1, $0 + 1, bot: $1.hasSuffix("[bot]")) })
}

private func threadsID(_ threads: [ReviewThreadInfo]) -> String? {
    Classifier.classify(pr(threads: threads), viewer: "me").items.first { $0.kind == .reviewThreads }?.id
}

@Test func resolvingOrOutdatingAThreadKeepsADismissalSticky() {
    let before = threadsID([thread(1), thread(2)])
    #expect(before != nil)
    #expect(threadsID([thread(1), thread(2, resolved: true)]) == before)
    #expect(threadsID([thread(1, outdated: true), thread(2)]) == before)
}

@Test func newConversationChangesTheReviewThreadsItem() {
    let before = threadsID([thread(1), thread(2)])
    #expect(threadsID([thread(1, replies: ["alice"]), thread(2)]) != before)  // a reply, even in an older thread
    #expect(threadsID([thread(1), thread(2), thread(3)]) != before)  // a new thread
    #expect(threadsID([thread(1), thread(2), thread(3, bot: true)]) == before)  // bots have their own item
}

@Test func theViewersOwnRepliesDontBringTheItemBack() {
    let before = threadsID([thread(1), thread(2)])
    #expect(threadsID([thread(1, replies: ["me"]), thread(2, replies: ["me", "me"])]) == before)
    #expect(threadsID([thread(1), thread(2, replies: ["cursor[bot]"])]) == before)
    #expect(threadsID([thread(1, replies: ["me", "alice"]), thread(2)]) != before)  // the reviewer answered back
}
