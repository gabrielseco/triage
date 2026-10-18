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

@Test func sameCreationDateFallsBackToPRNumber() {
    let a = item(3, createdAt: start)
    let b = item(4, createdAt: start)
    #expect([a, b].sortedByCreation().map(\.pr.number) == [4, 3])
}

private func extra(_ base: AttentionItem, _ name: String, _ severity: Severity) -> AttentionItem {
    var copy = base
    copy.id = "\(base.pr.id)|\(name)"
    copy.severity = severity
    return copy
}

@Test func everythingOrderNewestCreatedFirst() {
    let items = [1, 2, 3].map { item($0, createdAt: start.addingTimeInterval(Double($0 == 2 ? 30 : $0))) }
    #expect(items.sortedByCreation().map(\.pr.number) == [2, 3, 1])
}

@Test func everythingOrderTiesByHigherNumber() {
    let items = [5, 9, 7].map { item($0, createdAt: start) }
    #expect(items.sortedByCreation().map(\.pr.number) == [9, 7, 5])
}

@Test func everythingOrderKeepsAPullRequestsItemsTogetherAndInOrder() {
    let a = item(1, createdAt: start)
    let b = item(2, createdAt: start.addingTimeInterval(100))
    let a1 = extra(a, "x", .high)
    let a2 = extra(a, "y", .low)
    let b1 = extra(b, "x", .medium)
    let b2 = extra(b, "y", .low)
    let sorted = [a1, b1, a2, b2].sortedByCreation()
    #expect(sorted.map(\.id) == [b1.id, b2.id, a1.id, a2.id])
}

@Test func everythingOrderIgnoresRecentActivityOnAnOldPullRequest() {
    let old = item(1, createdAt: start, updatedAt: start.addingTimeInterval(99_999))
    let new = item(2, createdAt: start.addingTimeInterval(10), updatedAt: start.addingTimeInterval(10))
    #expect([old, new].sortedByCreation().map(\.pr.number) == [2, 1])
}
