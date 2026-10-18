import Foundation
import Testing

@testable import TriageCore

private let start = Date(timeIntervalSince1970: 1_000_000)

private func item(_ number: Int, createdAt: Date, updatedAt: Date = start, tag: String = "waiting") -> AttentionItem {
    let pr = PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/acme/web/pull/\(number)")!, author: "alice", createdAt: createdAt,
        updatedAt: updatedAt, headSha: "abc")
    return AttentionItem(
        id: "\(pr.id)|\(tag)", kind: .awaitingReview, severity: .low, pr: pr, headline: "Waiting for review",
        evidence: [])
}

@Test func newestOpenedPRComesFirstRegardlessOfActivity() {
    let old = item(1, createdAt: start, updatedAt: start.addingTimeInterval(9000))
    let new = item(2, createdAt: start.addingTimeInterval(3600))
    #expect([old, new].sortedByCreation().map(\.pr.number) == [2, 1])
}

@Test func sameCreationDateFallsBackToPRNumber() {
    let a = item(3, createdAt: start)
    let b = item(4, createdAt: start)
    #expect([a, b].sortedByCreation().map(\.pr.number) == [4, 3])
}

// MARK: - Everything

@Test func everythingOrderPutsTheNewestCreatedPRFirst() {
    let items = [
        item(1, createdAt: start.addingTimeInterval(3600)),
        item(2, createdAt: start),
        item(3, createdAt: start.addingTimeInterval(7200)),
    ]
    #expect(items.sortedByCreation().map(\.pr.number) == [3, 1, 2])
}

@Test func everythingOrderBreaksACreationTieByTheHighestNumber() {
    let items = [item(5, createdAt: start), item(9, createdAt: start), item(7, createdAt: start)]
    #expect(items.sortedByCreation().map(\.pr.number) == [9, 7, 5])
}

@Test func everythingOrderKeepsAPullRequestsItemsTogetherAndInTheirOrder() {
    let later = start.addingTimeInterval(3600)
    // The order Everything had before: worst first, so PR 1's items come apart around PR 2's.
    let items = [
        item(1, createdAt: start, tag: "c"), item(2, createdAt: later, tag: "x"),
        item(1, createdAt: start, tag: "a"), item(2, createdAt: later, tag: "y"),
        item(1, createdAt: start, tag: "b"),
    ]
    #expect(
        items.sortedByCreation().map(\.id) == [
            "acme/web#2|x", "acme/web#2|y", "acme/web#1|c", "acme/web#1|a", "acme/web#1|b",
        ])
}

@Test func everythingOrderDoesNotMoveUpAnOldPRThatWasJustUpdated() {
    let old = item(1, createdAt: start, updatedAt: start.addingTimeInterval(90_000))
    let new = item(2, createdAt: start.addingTimeInterval(3600), updatedAt: start.addingTimeInterval(3600))
    #expect([old, new].sortedByCreation().map(\.pr.number) == [2, 1])
}
