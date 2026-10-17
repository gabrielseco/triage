import Foundation
import Testing

@testable import TriageCore

private let start = Date(timeIntervalSince1970: 1_000_000)
private let gitlab = Forge.gitlab(host: "gitlab.example.com")

private func item(
    _ number: Int, by author: String, createdAt: Date = start, kind: AttentionKind = .botFinding,
    bot: String = "cursor", forge: Forge = .github
) -> AttentionItem {
    let pr = PullRequest(
        repo: RepoRef(owner: "acme", name: "web", forge: forge), number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/acme/web/pull/\(number)")!, author: author, createdAt: createdAt,
        updatedAt: start, headSha: "abc")
    return AttentionItem(
        id: "\(pr.id)|bot|\(bot)", kind: kind, severity: .medium, pr: pr, headline: "\(bot): finding",
        evidence: [])
}

private func me(_ forge: Forge) -> String? { forge == .github ? "me" : nil }

@Test func botFindingOrderPutsMineBeforeOthers() {
    let theirs = item(1, by: "alice", createdAt: start.addingTimeInterval(3600))
    let mine = item(2, by: "me")
    #expect([theirs, mine].sortedAsBotFindings(viewer: me).map(\.pr.number) == [2, 1])
}

@Test func botFindingOrderSortsEachGroupByCreationDate() {
    let oldMine = item(1, by: "me")
    let newMine = item(2, by: "me", createdAt: start.addingTimeInterval(60))
    let oldTheirs = item(3, by: "alice")
    let newTheirs = item(4, by: "bob", createdAt: start.addingTimeInterval(60))
    let sorted = [oldTheirs, oldMine, newTheirs, newMine].sortedAsBotFindings(viewer: me)
    #expect(sorted.map(\.pr.number) == [2, 1, 4, 3])
}

@Test func botFindingOrderBreaksTiesByNumber() {
    let a = item(3, by: "alice")
    let b = item(4, by: "alice")
    #expect([a, b].sortedAsBotFindings(viewer: me).map(\.pr.number) == [4, 3])
}

@Test func botFindingOrderKeepsItemsOfOnePRInOrder() {
    let first = item(5, by: "me", bot: "cursor")
    let second = item(5, by: "me", bot: "sonar")
    let other = item(6, by: "me", createdAt: start.addingTimeInterval(60))
    let sorted = [first, second, other].sortedAsBotFindings(viewer: me)
    #expect(sorted.map(\.id) == [other.id, first.id, second.id])
    #expect([second, first].sortedAsBotFindings(viewer: me).map(\.id) == [second.id, first.id])
}

@Test func botFindingOrderWithoutViewerIsNewestFirst() {
    let mine = item(1, by: "me")
    let theirs = item(2, by: "alice", createdAt: start.addingTimeInterval(60))
    #expect([mine, theirs].sortedAsBotFindings(viewer: { _ in nil }).map(\.pr.number) == [2, 1])
}

@Test func botFindingOrderUsesTheGitLabViewerOnGitLab() {
    let viewer: (Forge) -> String? = { $0 == gitlab ? "gl-me" : "me" }
    let theirs = item(1, by: "me", createdAt: start.addingTimeInterval(60), forge: gitlab)
    let mine = item(2, by: "gl-me", forge: gitlab)
    #expect([theirs, mine].sortedAsBotFindings(viewer: viewer).map(\.pr.number) == [2, 1])
}

@Test func fixActionsHiddenOnSomeoneElsesBotFinding() {
    #expect(!item(1, by: "alice").showsFixActions(viewer: "me"))
}

@Test func fixActionsShownOnMyBotFinding() {
    #expect(item(1, by: "me").showsFixActions(viewer: "me"))
}

@Test func fixActionsShownWhenViewerIsUnknown() {
    #expect(item(1, by: "alice").showsFixActions(viewer: nil))
}

@Test func fixActionsShownForOtherKindsOnSomeoneElsesPR() {
    for kind in AttentionKind.allCases where kind != .botFinding {
        #expect(item(1, by: "alice", kind: kind).showsFixActions(viewer: "me"))
    }
}
