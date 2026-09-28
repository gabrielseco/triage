import Foundation
import Testing

@testable import TriageCore

private let web = RepoRef(owner: "acme", name: "web")
private let api = RepoRef(owner: "acme", name: "api")
private let start = Date(timeIntervalSince1970: 1_000_000)

private func pr(_ number: Int, in repo: RepoRef = web, createdAt: Date) -> PullRequest {
    PullRequest(
        repo: repo, number: number, title: "PR \(number)", url: URL(string: "https://github.com/acme/web/pull/1")!,
        author: "alice", createdAt: createdAt, headSha: "abc")
}

@Test func prsOpenedBeforeWatchingAreNotNew() {
    var seen = SeenPRs()
    seen.startWatching([web], now: start)
    #expect(!seen.isNew(pr(1, createdAt: start.addingTimeInterval(-60))))
    #expect(seen.isNew(pr(2, createdAt: start.addingTimeInterval(60))))
}

@Test func unwatchedRepoHasNothingNew() {
    let seen = SeenPRs()
    #expect(!seen.isNew(pr(1, createdAt: .now)))
}

@Test func laterFetchesKeepTheOriginalStart() {
    var seen = SeenPRs()
    seen.startWatching([web], now: start)
    seen.startWatching([web, api], now: start.addingTimeInterval(3600))
    #expect(seen.isNew(pr(2, createdAt: start.addingTimeInterval(60))))
    #expect(!seen.isNew(pr(3, in: api, createdAt: start.addingTimeInterval(60))))
}

@Test func dismissedPRStaysSeenAndOthersStayNew() {
    var seen = SeenPRs()
    seen.startWatching([web], now: start)
    let a = pr(2, createdAt: start.addingTimeInterval(60))
    let b = pr(3, createdAt: start.addingTimeInterval(120))
    seen.dismiss(a)
    #expect(!seen.isNew(a))
    #expect(seen.isNew(b))
}

@Test func dismissingInAnUnwatchedRepoDoesNotStartIt() {
    var seen = SeenPRs()
    seen.dismiss(pr(2, createdAt: .now))
    #expect(seen.repos.isEmpty)
}

@Test func stoppingWatchingRestartsTheClock() {
    var seen = SeenPRs()
    seen.startWatching([web], now: start)
    seen.stopWatching(web)
    seen.startWatching([web], now: start.addingTimeInterval(3600))
    #expect(!seen.isNew(pr(2, createdAt: start.addingTimeInterval(60))))
}

@Test func seenPRsSurviveARoundTrip() throws {
    var seen = SeenPRs()
    seen.startWatching([web], now: start)
    seen.dismiss(pr(2, createdAt: start.addingTimeInterval(60)))
    let decoded = try JSONDecoder().decode(SeenPRs.self, from: JSONEncoder().encode(seen))
    #expect(decoded == seen)
}

@Test func undismissAllBringsNewPRsBackButKeepsTheClock() {
    var seen = SeenPRs()
    seen.startWatching([web], now: start)
    let a = pr(2, createdAt: start.addingTimeInterval(60))
    seen.dismiss(a)
    seen.undismissAll()
    #expect(seen.isNew(a))
    #expect(!seen.isNew(pr(1, createdAt: start.addingTimeInterval(-60))))
}
