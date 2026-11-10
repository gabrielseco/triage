import Foundation
import Testing

@testable import TriageCore

private let inPR = "9f3c2e1a7b4d5e6f8091a2b3c4d5e6f708192a3b"
private let otherCommit = "0123456789abcdef0123456789abcdef01234567"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private func comment(_ author: String, bot: Bool = false, _ body: String, minutes: Double) -> CommentInfo {
    CommentInfo(
        author: author, isBot: bot, body: body, url: URL(string: "https://github.com/acme/web/pull/1#c\(Int(minutes))"),
        createdAt: at(minutes))
}

private func thread(
    resolved: Bool = false, by: String? = nil, path: String = "a.swift", bot: Bool = true, replies: [CommentInfo] = []
) -> ReviewThreadInfo {
    ReviewThreadInfo(
        isResolved: resolved, resolvedBy: by, path: path, line: 1,
        firstComment: comment("cursor[bot]", bot: bot, "### Bug\n**High Severity**", minutes: 0),
        commentCount: 1 + replies.count, replies: replies)
}

private func pr(threads: [ReviewThreadInfo]) -> PullRequest {
    PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: 1, title: "t",
        url: URL(string: "https://github.com/acme/web/pull/1")!, author: "gabi", headSha: inPR, threads: threads,
        commitShas: [otherCommit.replacingOccurrences(of: "0123", with: "7777"), inPR])
}

private let commits = [inPR]

@Suite struct ThreadStateTests {
    @Test func threadStates() {
        let fixed = thread(replies: [comment("gabi", "Fixed in \(inPR.prefix(7))", minutes: 5)])
        let states = ThreadStates.states(
            [thread(), fixed, thread(resolved: true, by: "gabi")], prCommits: commits)
        #expect(states == [.open, .fixReported(commit: inPR), .resolved(by: "gabi")])
        #expect(states.map(\.label) == [nil, "Fixed in 9f3c2e1", "Resolved"])
        // Resolved wins over a reported fix.
        let both = thread(resolved: true, replies: [comment("gabi", "Fixed in \(inPR)", minutes: 5)])
        #expect(ThreadStates.state(of: both, prCommits: commits) == .resolved(by: nil))
    }

    @Test func fixReportedCommitMatching() {
        func state(_ body: String, bot: Bool = false, commits: [String] = commits) -> ThreadState {
            ThreadStates.state(
                of: thread(replies: [comment("gabi", bot: bot, body, minutes: 5)]), prCommits: commits)
        }
        let link = "https://github.com/acme/web/commit/"
        #expect(state("Done: \(link)\(inPR)") == .fixReported(commit: inPR))
        #expect(state("done in \(inPR.prefix(7)).") == .fixReported(commit: inPR))
        #expect(state("done in \(inPR.prefix(7).uppercased())") == .fixReported(commit: inPR))
        // A commit outside the pull request, or no commit at all, reports nothing.
        #expect(state("Done: \(link)\(otherCommit)") == .open)
        #expect(state("Fixed, I think") == .open)
        #expect(state("see 9f3c2e") == .open)  // too short to be a SHA
        #expect(state("Done in \(inPR)", bot: true) == .open)  // only a person reports a fix
        #expect(state("Done in \(inPR)", commits: []) == .open)
        // The opening comment is not a reply.
        let opening = ReviewThreadInfo(
            isResolved: false, firstComment: comment("gabi", "Moved in \(inPR)", minutes: 0))
        #expect(ThreadStates.state(of: opening, prCommits: commits) == .open)
        // A human thread works the same way.
        let human = ReviewThreadInfo(
            isResolved: false, firstComment: comment("maria", "why?", minutes: 0),
            replies: [comment("gabi", "fixed in \(inPR.prefix(10))", minutes: 2)])
        #expect(ThreadStates.state(of: human, prCommits: commits) == .fixReported(commit: inPR))
    }

    @Test func botReplyAfterFix() {
        let fix = comment("gabi", "Fixed in \(inPR.prefix(7))", minutes: 5)
        let stillThere = comment("cursor[bot]", bot: true, "Still reproduces.", minutes: 9)
        #expect(ThreadStates.state(of: thread(replies: [fix, stillThere]), prCommits: commits) == .open)
        // A bot reply before the fix doesn't undo it, and a newer fix does.
        let early = comment("cursor[bot]", bot: true, "Looking.", minutes: 2)
        #expect(
            ThreadStates.state(of: thread(replies: [early, fix]), prCommits: commits)
                == .fixReported(commit: inPR))
        let again = comment("gabi", "Really fixed in \(inPR.prefix(8))", minutes: 12)
        #expect(
            ThreadStates.state(of: thread(replies: [fix, stillThere, again]), prCommits: commits)
                == .fixReported(commit: inPR))
    }

    @Test func stickyItemIds() {
        let open = thread(path: "a.swift")
        let other = ReviewThreadInfo(
            isResolved: false, path: "b.swift", line: 2,
            firstComment: comment("cursor[bot]", bot: true, "Another", minutes: 3))
        let fixed = thread(path: "a.swift", replies: [comment("gabi", "Fixed in \(inPR)", minutes: 5)])
        let resolved = ReviewThreadInfo(
            isResolved: true, resolvedBy: "gabi", path: "b.swift", line: 2, firstComment: other.firstComment)

        let ids = [[open, other], [fixed, other], [fixed, resolved], [open, resolved]].map { threads in
            Classifier.classify(pr(threads: threads)).items.filter { $0.kind == .botFinding }.map(\.id)
        }
        #expect(ids[0].count == 1)
        #expect(Set(ids.flatMap { $0 }).count == 1)
    }

    @Test func resolvedFindingsStayListedForTheSession() {
        let a = thread(path: "a.swift")
        let b = ReviewThreadInfo(
            isResolved: false, path: "b.swift", line: 2,
            firstComment: comment("cursor[bot]", bot: true, "### Another", minutes: 3))
        let before = Classifier.classify(pr(threads: [a, b])).items.filter { $0.kind == .botFinding }
        #expect(before.count == 1)
        #expect(!before[0].isResolved)

        var one = b
        one.isResolved = true
        let partly = Classifier.classify(pr(threads: [a, one])).items.filter { $0.kind == .botFinding }
        #expect(partly.map(\.id) == before.map(\.id))
        #expect(partly[0].evidence.map(\.threadState) == [.open, .resolved(by: nil)])

        var two = a
        two.isResolved = true
        let all = pr(threads: [two, one])
        // Nothing open and not seen this session: gone. Seen earlier this session: kept, resolved, not urgent.
        #expect(Classifier.classify(all).items.filter { $0.kind == .botFinding }.isEmpty)
        let kept = Classifier.classify(all, retaining: Set(before.map(\.id))).items.filter { $0.kind == .botFinding }
        #expect(kept.map(\.id) == before.map(\.id))
        #expect(kept[0].isResolved)
        #expect(kept[0].severity == .info)
        #expect(kept[0].evidence.map(\.threadState).allSatisfy { $0 != .open })
    }

    @Test func fixReportedShowsOnTheEvidence() {
        let fixed = thread(replies: [comment("gabi", "Fixed in \(inPR.prefix(7))", minutes: 5)])
        let item = Classifier.classify(pr(threads: [fixed])).items.first { $0.kind == .botFinding }
        #expect(item?.evidence.first?.threadState?.label == "Fixed in 9f3c2e1")
    }
}

@Test func defaultMockExercisesEveryThreadState() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Mocks/default.json")
    let scenario = try MockScenario.load(from: file)
    let prs = try scenario.pullRequests.map { try MockWorld.pullRequest($0, scenario: scenario, now: .now) }
    let states = prs.flatMap { pr in pr.threads.map { pr.state(of: $0) } }
    #expect(states.contains(.open))
    #expect(states.contains { if case .fixReported = $0 { true } else { false } })
    #expect(states.contains(.resolved(by: "gabi")))
}
