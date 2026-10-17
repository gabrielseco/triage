import Foundation
import Testing

@testable import TriageCore

private let start = Date(timeIntervalSince1970: 1_000_000)
private let gitlab = Forge.gitlab(host: "gitlab.example.com")

private func item(
    _ number: Int, by author: String, createdAt: Date = start, kind: AttentionKind = .ciFailure,
    severity: Severity = .medium, forge: Forge = .github
) -> AttentionItem {
    let pr = PullRequest(
        repo: RepoRef(owner: "acme", name: "web", forge: forge), number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/acme/web/pull/\(number)")!, author: author, createdAt: createdAt,
        updatedAt: start, headSha: "abc")
    return AttentionItem(
        id: "\(pr.id)|\(kind.rawValue)", kind: kind, severity: severity, pr: pr, headline: "PR \(number)",
        evidence: [])
}

private func me(_ forge: Forge) -> String? { forge == .github ? "me" : nil }

@Test func everythingOrderPutsMineBeforeOthers() {
    let theirs = item(1, by: "alice", createdAt: start.addingTimeInterval(3600), severity: .high)
    let mine = item(2, by: "me", severity: .low)
    #expect([theirs, mine].sortedMineFirst(viewer: me).map(\.pr.number) == [2, 1])
}

@Test func everythingOrderSortsEachGroupByCreationDate() {
    let oldMine = item(1, by: "me", severity: .high)
    let newMine = item(2, by: "me", createdAt: start.addingTimeInterval(60))
    let oldTheirs = item(3, by: "alice", severity: .high)
    let newTheirs = item(4, by: "bob", createdAt: start.addingTimeInterval(60))
    let sorted = [oldMine, oldTheirs, newTheirs, newMine].sortedMineFirst(viewer: me)
    #expect(sorted.map(\.pr.number) == [2, 1, 4, 3])
}

@Test func everythingOrderBreaksTiesByNumber() {
    let a = item(3, by: "alice")
    let b = item(4, by: "alice")
    #expect([a, b].sortedMineFirst(viewer: me).map(\.pr.number) == [4, 3])
}

@Test func everythingOrderKeepsItemsOfOnePRInOrder() {
    let worst = item(5, by: "me", kind: .ciFailure, severity: .high)
    let lesser = item(5, by: "me", kind: .reviewThreads, severity: .medium)
    let other = item(6, by: "me", createdAt: start.addingTimeInterval(60))
    let sorted = [worst, lesser, other].sortedMineFirst(viewer: me)
    #expect(sorted.map(\.id) == [other.id, worst.id, lesser.id])
    #expect([lesser, worst].sortedMineFirst(viewer: me).map(\.id) == [lesser.id, worst.id])
}

@Test func everythingOrderWithoutViewerIsNewestFirst() {
    let mine = item(1, by: "me")
    let theirs = item(2, by: "alice", createdAt: start.addingTimeInterval(60))
    #expect([mine, theirs].sortedMineFirst(viewer: { _ in nil }).map(\.pr.number) == [2, 1])
}

@Test func everythingOrderUsesTheGitLabViewerOnGitLab() {
    let viewer: (Forge) -> String? = { $0 == gitlab ? "gl-me" : "me" }
    let theirs = item(1, by: "me", createdAt: start.addingTimeInterval(60), forge: gitlab)
    let mine = item(2, by: "gl-me", forge: gitlab)
    #expect([theirs, mine].sortedMineFirst(viewer: viewer).map(\.pr.number) == [2, 1])
}
