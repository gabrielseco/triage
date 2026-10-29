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

// MARK: - Review requested

private func reviewItem(_ number: Int, repo: String = "web", createdAt: Date) -> AttentionItem {
    let pr = PullRequest(
        repo: RepoRef(owner: "acme", name: repo), number: number, title: "PR \(number)",
        url: URL(string: "https://github.com/acme/\(repo)/pull/\(number)")!, author: "alice", createdAt: createdAt,
        updatedAt: start, headSha: "abc")
    return AttentionItem(
        id: "\(pr.id)|review", kind: .reviewRequested, severity: .low, pr: pr, headline: "Review requested",
        evidence: [])
}

@Test func reviewRequestedOrdering() {
    let items = [
        reviewItem(5, createdAt: start.addingTimeInterval(100)),
        reviewItem(9, createdAt: start),
        reviewItem(7, createdAt: start),
        reviewItem(3, repo: "api", createdAt: start),
    ]
    // Oldest opened first; ties by repo id, then lowest number.
    #expect(
        items.sortedForReview().map(\.id) == [
            "acme/api#3|review", "acme/web#7|review", "acme/web#9|review", "acme/web#5|review",
        ])
}

@Test func reviewRequestedOrderIsStable() {
    let items = [
        reviewItem(1, createdAt: start), reviewItem(2, createdAt: start), reviewItem(3, repo: "api", createdAt: start),
        reviewItem(4, createdAt: start.addingTimeInterval(5)),
    ]
    let expected = items.sortedForReview().map(\.id)
    #expect(items.reversed().sortedForReview().map(\.id) == expected)
    #expect(items.shuffled().sortedForReview().map(\.id) == expected)
}

// MARK: - Repo

private let gitlab = Forge.gitlab(host: "gitlab.example.com")

private func gitlabItem(
    _ number: Int, repo: RepoRef, createdAt: Date, updatedAt: Date, severity: Severity = .low
) -> AttentionItem {
    let pr = PullRequest(
        repo: repo, number: number, title: "MR \(number)",
        url: URL(string: "https://gitlab.example.com/\(repo.owner)/\(repo.name)/-/merge_requests/\(number)")!,
        author: "alice", createdAt: createdAt, updatedAt: updatedAt, headSha: "abc")
    return AttentionItem(
        id: "\(pr.id)|waiting", kind: .awaitingReview, severity: severity, pr: pr, headline: "Waiting for review",
        evidence: [])
}

@Test func repoOrderPutsTheNewerGitLabMergeRequestFirstEvenIfTheOldOneWasJustUpdated() {
    let api = RepoRef(owner: "platform", name: "api", forge: gitlab)
    let web = RepoRef(owner: "platform", name: "web", forge: gitlab)
    let hour = start.addingTimeInterval(3600)
    // activeItems' order: worst first, then most recently updated, so the old MR leads.
    let items = [
        gitlabItem(1, repo: api, createdAt: start, updatedAt: start.addingTimeInterval(90_000), severity: .high),
        gitlabItem(5, repo: web, createdAt: start.addingTimeInterval(9000), updatedAt: start),
        gitlabItem(2, repo: api, createdAt: hour, updatedAt: hour),
    ]
    #expect(items.inRepo(api.id).map(\.pr.number) == [2, 1])
}

@Test func repoOrderKeepsOnlyThatRepoAndBreaksTiesByTheHighestNumber() {
    let api = RepoRef(owner: "platform", name: "api", forge: gitlab)
    let items = [
        gitlabItem(3, repo: api, createdAt: start, updatedAt: start),
        item(8, createdAt: start.addingTimeInterval(7200)),
        gitlabItem(4, repo: api, createdAt: start, updatedAt: start),
    ]
    #expect(items.inRepo(api.id).map(\.pr.number) == [4, 3])
    #expect(items.inRepo("acme/web").map(\.pr.number) == [8])
}
