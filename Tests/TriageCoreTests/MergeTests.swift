import Foundation
import Testing

@testable import TriageCore

private func pr(
    author: String = "me", approvedBy: Set<String> = [], draft: Bool = false, mergeable: Mergeable = .mergeable,
    review: ReviewDecision = .approved,
    checks: [CheckState] = [.success]
) -> PullRequest {
    PullRequest(
        repo: RepoRef(owner: "o", name: "r"), number: 1, title: "t", url: URL(string: "https://github.com/o/r/pull/1")!,
        author: author, isDraft: draft, headSha: "abc", mergeable: mergeable, reviewDecision: review,
        approvedBy: approvedBy,
        checks: checks.enumerated().map { CheckInfo(name: "c\($0.offset)", state: $0.element) })
}

@Test func greenApprovedPRHasNoBlockerOrWarnings() {
    #expect(pr().mergeBlocker == nil)
    #expect(pr().mergeWarnings.isEmpty)
    #expect(pr(review: .none, checks: []).mergeWarnings.isEmpty)
}

@Test func draftsAndConflictsCantBeMerged() {
    #expect(pr(draft: true).mergeBlocker == "Draft")
    #expect(pr(mergeable: .conflicting).mergeBlocker == "Merge conflicts")
    #expect(pr(draft: true, mergeable: .conflicting).mergeBlocker == "Draft")
    #expect(pr(mergeable: .unknown).mergeBlocker == nil)
}

@Test func failingChecksAndReviewsBlockOnlyWhenBranchProtectionDoes() {
    func blocked(_ p: PullRequest, _ state: MergeState = .blocked) -> String? {
        var p = p
        p.mergeState = state
        return p.mergeBlocker
    }
    #expect(pr(review: .reviewRequired, checks: [.failure]).mergeBlocker == nil)
    #expect(blocked(pr(review: .reviewRequired, checks: [.failure])) == "Checks failing")
    #expect(blocked(pr(review: .reviewRequired)) == "Review required")
    #expect(blocked(pr(review: .changesRequested)) == "Changes requested")
    #expect(blocked(pr(checks: [.pending])) == "Checks running")
    #expect(blocked(pr()) == "Blocked by branch protection")
    #expect(blocked(pr(), .behind) == "Branch out of date")
    #expect(blocked(pr(draft: true)) == "Draft")
    for state in [MergeState.clean, .unstable, .hasHooks, .unknown] { #expect(blocked(pr(), state) == nil) }
}

@Test func anAdminCanMergePastBranchProtection() {
    func blocked(_ p: PullRequest, admin: Bool) -> PullRequest {
        var p = p
        p.mergeState = .blocked
        p.viewerCanMergeAsAdmin = admin
        return p
    }
    let failing = pr(review: .reviewRequired, checks: [.failure])
    #expect(blocked(failing, admin: false).mergeBlocker == "Checks failing")
    #expect(blocked(failing, admin: true).mergeBlocker == nil)
    #expect(blocked(failing, admin: true).mergeNote == "Checks failing")
    #expect(blocked(pr(review: .reviewRequired), admin: true).mergeNote == "Review required")
    #expect(blocked(pr(), admin: true).mergeBlocker == nil)
    #expect(blocked(pr(), admin: true).mergeNote == "Blocked by branch protection")
    // Drafts and conflicts still block an admin.
    #expect(blocked(pr(draft: true), admin: true).mergeBlocker == "Draft")
    #expect(blocked(pr(mergeable: .conflicting), admin: true).mergeBlocker == "Merge conflicts")
}

@Test func conflictingPRShowsTheConflictBlocker() {
    let p = pr(mergeable: .conflicting, review: .reviewRequired, checks: [.failure])
    #expect(p.mergeBlocker == "Merge conflicts")
    #expect(p.mergeNote == "Merge conflicts")
}

@Test func failingChecksAndReviewsAreNotedBesideAnEnabledMerge() {
    #expect(pr().mergeNote == nil)
    #expect(pr(review: .reviewRequired, checks: [.failure]).mergeNote == "Checks failing")
    #expect(pr(review: .reviewRequired, checks: [.failure]).mergeBlocker == nil)
    #expect(pr(review: .reviewRequired).mergeNote == "Review required")
    #expect(pr(review: .changesRequested).mergeNote == "Changes requested")
    #expect(pr(checks: [.pending]).mergeNote == "Checks running")
    #expect(pr(draft: true, checks: [.failure]).mergeNote == "Draft")
}

@Test func defaultMethodFallsBackToTheFirstAllowedOne() {
    var p = pr()
    #expect(p.mergeMethods == [.merge, .squash, .rebase])
    #expect(p.defaultMergeMethod == .merge)
    p.mergeMethod = .squash
    #expect(p.defaultMergeMethod == .squash)
    p.allowedMergeMethods = [.rebase, .merge]
    #expect(p.mergeMethods == [.merge, .rebase])
    #expect(p.defaultMergeMethod == .merge)
}

@Test func warningsCoverChecksReviewsAndMergeability() {
    let p = pr(mergeable: .unknown, review: .changesRequested, checks: [.failure, .failure, .pending, .success])
    #expect(
        p.mergeWarnings == [
            "2 checks are failing", "1 check is still running", "A reviewer requested changes",
            "GitHub is still checking mergeability",
        ])
    #expect(pr(review: .reviewRequired).mergeWarnings == ["It isn't approved yet"])
}

@Test func mergeMethodMapsToRESTValues() {
    #expect(MergeMethod.allCases.map(\.restValue) == ["merge", "squash", "rebase"])
}

@Test func onlyOthersReadyPRsYouHaventApprovedCanBeApproved() {
    #expect(pr(author: "teammate").canBeApproved(by: "me"))
    #expect(!pr(author: "me").canBeApproved(by: "me"))
    #expect(!pr(author: "teammate", approvedBy: ["me"]).canBeApproved(by: "me"))
    #expect(pr(author: "teammate", approvedBy: ["someone"]).canBeApproved(by: "me"))
    #expect(!pr(author: "teammate", draft: true).canBeApproved(by: "me"))
    #expect(!pr(author: "teammate").canBeApproved(by: nil))
}
