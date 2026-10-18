import Foundation
import Testing

@testable import TriageCore

private let start = Date(timeIntervalSince1970: 1_000_000)

private func item(
    _ number: Int, createdAt: Date, updatedAt: Date = start, id: String? = nil, severity: Severity = .low
) -> AttentionItem {
    let pr = PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/acme/web/pull/\(number)")!, author: "alice", createdAt: createdAt,
        updatedAt: updatedAt, headSha: "abc")
    return AttentionItem(
        id: id ?? "\(pr.id)|waiting", kind: .awaitingReview, severity: severity, pr: pr, headline: "Waiting for review",
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

@Test func everythingOrderNewestCreatedFirst() {
    let items = [1, 2, 3].map { item($0, createdAt: start.addingTimeInterval(Double($0 == 2 ? 30 : $0) * 60)) }
    #expect(items.sortedByCreation().map(\.pr.number) == [2, 3, 1])
}

@Test func everythingOrderTiesByNumberHighestFirst() {
    let items = [5, 9, 7].map { item($0, createdAt: start) }
    #expect(items.sortedByCreation().map(\.pr.number) == [9, 7, 5])
}

@Test func everythingOrderKeepsItemsOfOnePRInOrderAndTogether() {
    let a1 = item(1, createdAt: start, id: "a1", severity: .high)
    let a2 = item(1, createdAt: start, id: "a2", severity: .medium)
    let a3 = item(1, createdAt: start, id: "a3", severity: .low)
    let b = item(2, createdAt: start.addingTimeInterval(-60))
    let sorted = [a1, b, a2, a3].sortedByCreation()
    #expect(sorted.map(\.id) == ["a1", "a2", "a3", b.id])
}

@Test func everythingOrderRecentUpdateOnOldPRDoesNotMoveUp() {
    let old = item(1, createdAt: start, updatedAt: start.addingTimeInterval(99_999))
    let new = item(2, createdAt: start.addingTimeInterval(60), updatedAt: start)
    #expect([old, new].sortedByCreation().map(\.pr.number) == [2, 1])
}
