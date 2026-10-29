import Foundation
import Testing

@testable import TriageCore

@Suite struct ReviewRequestedOrderTests {
    private func item(
        _ repo: String, _ number: Int, created: Double, draft: Bool = false, failing: Bool = false
    ) -> AttentionItem {
        let pr = PullRequest(
            repo: RepoRef(owner: "acme", name: repo), number: number, title: "t",
            url: URL(string: "https://github.com/acme/\(repo)/pull/\(number)")!, author: "rita", isDraft: draft,
            createdAt: Date(timeIntervalSince1970: created), headSha: "a",
            checks: failing ? [CheckInfo(name: "ci", state: .failure)] : [CheckInfo(name: "ci", state: .success)])
        return AttentionItem(
            id: "\(pr.id)-review", kind: .reviewRequested, severity: .medium, pr: pr, headline: "h", evidence: [])
    }

    private func ids(_ items: [AttentionItem]) -> [String] { items.map(\.pr.id) }

    @Test func reviewOrientedOrdering() {
        let items = [
            item("web", 5, created: 10, draft: true),
            item("web", 4, created: 20, failing: true),
            item("web", 3, created: 300),
            item("web", 2, created: 100),
            item("api", 9, created: 100),
            item("web", 1, created: 100),
        ]
        // Ready and passing first, oldest first, ties by repo then number; then failing; then drafts.
        #expect(
            ids(items.sortedForReview()) == [
                "acme/api#9", "acme/web#1", "acme/web#2", "acme/web#3", "acme/web#4", "acme/web#5",
            ])
    }

    @Test func otherKindsKeepTheirOrder() {
        let items = [item("web", 2, created: 100, draft: true), item("web", 1, created: 50)]
        #expect(ids(items.orderedForList(of: .ciFailure)) == ["acme/web#2", "acme/web#1"])
        #expect(ids(items.orderedForList(of: .reviewRequested)) == ["acme/web#1", "acme/web#2"])
    }

    @Test func stableAcrossRefreshes() {
        let items = [
            item("web", 1, created: 100), item("web", 2, created: 100), item("api", 3, created: 50),
            item("web", 4, created: 10, draft: true), item("web", 5, created: 10, failing: true),
        ]
        let expected = ids(items.sortedForReview())
        for shuffled in [items.reversed(), Array(items[2...] + items[..<2]), items.sorted { $0.id > $1.id }] {
            #expect(ids(shuffled.sortedForReview()) == expected)
        }

        // A relevant change (the oldest PR goes draft) moves it.
        var changed = items
        changed[2].pr.isDraft = true
        #expect(ids(changed.sortedForReview()).first == "acme/web#1")
        #expect(ids(changed.sortedForReview()).contains("acme/api#3"))
        #expect(ids(changed.sortedForReview()) != expected)
    }
}
