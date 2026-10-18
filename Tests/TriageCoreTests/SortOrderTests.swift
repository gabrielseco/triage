import Foundation
import Testing

@testable import TriageCore

private let start = Date(timeIntervalSince1970: 1_000_000)

private func item(_ number: Int, createdAt: Date, updatedAt: Date = start) -> AttentionItem {
    let pr = PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/acme/web/pull/\(number)")!, author: "alice", createdAt: createdAt,
        updatedAt: updatedAt, headSha: "abc")
    return AttentionItem(
        id: "\(pr.id)|waiting", kind: .awaitingReview, severity: .low, pr: pr, headline: "Waiting for review",
        evidence: [])
}

@Test func newestOpenedPRComesFirstRegardlessOfActivity() {
    let old = item(1, createdAt: start, updatedAt: start.addingTimeInterval(9000))
    let new = item(2, createdAt: start.addingTimeInterval(3600))
    #expect([old, new].sortedByCreation().map(\.pr.number) == [2, 1])
}

private func entry(
    _ number: Int, _ tag: String, createdAt: Date, updatedAt: Date = start, severity: Severity = .low
) -> AttentionItem {
    var i = item(number, createdAt: createdAt, updatedAt: updatedAt)
    i.id = "\(i.pr.id)|\(tag)"
    i.severity = severity
    return i
}

@Test func everythingOrderNewestCreatedFirst() {
    let old = entry(1, "a", createdAt: start, severity: .high)
    let mid = entry(2, "a", createdAt: start.addingTimeInterval(100), severity: .low)
    let new = entry(3, "a", createdAt: start.addingTimeInterval(200), severity: .low)
    #expect([old, mid, new].sortedByCreation().map(\.pr.number) == [3, 2, 1])
}

@Test func everythingOrderTiesByPRNumber() {
    let items = [5, 9, 7].map { entry($0, "a", createdAt: start) }
    #expect(items.sortedByCreation().map(\.pr.number) == [9, 7, 5])
}

@Test func everythingOrderPreservesItemsWithinEachPullRequest() {
    let t1 = start.addingTimeInterval(100)
    let input = [
        entry(1, "x", createdAt: start), entry(2, "p", createdAt: t1), entry(1, "y", createdAt: start),
        entry(2, "q", createdAt: t1), entry(1, "z", createdAt: start),
    ]
    let sorted = input.sortedByCreation()
    #expect(sorted.map(\.id) == [input[1], input[3], input[0], input[2], input[4]].map(\.id))
    #expect(sorted.map(\.pr.number) == [2, 2, 1, 1, 1])
}

@Test func everythingOrderRecentUpdateDoesNotPromoteOldPullRequest() {
    let old = entry(1, "a", createdAt: start, updatedAt: start.addingTimeInterval(99999), severity: .high)
    let new = entry(2, "a", createdAt: start.addingTimeInterval(100))
    #expect([old, new].sortedByCreation().map(\.pr.number) == [2, 1])
}

@Test func sameCreationDateFallsBackToPRNumber() {
    let a = item(3, createdAt: start)
    let b = item(4, createdAt: start)
    #expect([a, b].sortedByCreation().map(\.pr.number) == [4, 3])
}
