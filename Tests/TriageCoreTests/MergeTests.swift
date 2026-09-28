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
    #expect(pr(draft: true).mergeBlocker == "It's a draft")
    #expect(pr(mergeable: .conflicting).mergeBlocker == "It conflicts with the base branch")
    #expect(pr(mergeable: .unknown).mergeBlocker == nil)
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
