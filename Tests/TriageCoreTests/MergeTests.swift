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

@Test func anAdminCanMergeABranchThatIsBehind() {
    func behind(admin: Bool) -> PullRequest {
        var p = pr()
        p.mergeState = .behind
        p.viewerCanMergeAsAdmin = admin
        return p
    }
    #expect(behind(admin: false).mergeBlocker == "Branch out of date")
    #expect(behind(admin: false).mergeNote == "Branch out of date")
    #expect(behind(admin: true).mergeBlocker == nil)
    #expect(behind(admin: true).mergeNote == "Branch out of date")
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

private func mr(
    _ status: DetailedMergeStatus?, draft: Bool = false, checks: [CheckState] = [.success]
) throws -> PullRequest {
    var p = pr(draft: draft, checks: checks)
    p.repo = try #require(RepoRef(gitlabPath: "acme/web", host: "gitlab.example.com"))
    p.detailedMergeStatus = status
    p.allowedMergeMethods = [.merge, .squash]
    return p
}

@Test func gitlabConflictsRebaseDraftsAndCheckingDisableMerge() throws {
    let cases: [(DetailedMergeStatus, String)] = [
        (.conflict, "Merge conflicts"), (.needRebase, "Branch needs a rebase"), (.draft, "Draft"),
        (.checking, "GitLab is checking mergeability"), (.unchecked, "GitLab is checking mergeability"),
    ]
    for (status, reason) in cases {
        let p = try mr(status)
        #expect(p.mergeBlocker == reason, "\(status)")
        #expect(p.mergeNote == reason, "\(status)")
    }
    #expect(try mr(.mergeable, draft: true).mergeBlocker == "Draft")
}

@Test func gitlabApprovalsPipelinesAndThreadsAreNotedBesideAnEnabledMerge() throws {
    let cases: [(DetailedMergeStatus, String)] = [
        (.notApproved, "Approval required"), (.ciMustPass, "Pipeline must succeed"),
        (.discussionsNotResolved, "Unresolved threads"),
    ]
    for (status, note) in cases {
        let p = try mr(status)
        #expect(p.mergeBlocker == nil, "\(status)")
        #expect(p.mergeNote == note, "\(status)")
    }
    #expect(try mr(.mergeable).mergeBlocker == nil)
    #expect(try mr(.mergeable).mergeNote == nil)
    // No status to go on: the checks and reviews say what to think twice about, as on GitHub.
    #expect(try mr(nil, checks: [.failure]).mergeNote == "Checks failing")
}

@Test func gitlabCautionsHeadAnEnabledMergeAndPipelineRunningToo() throws {
    let cases: [(DetailedMergeStatus, String)] = [
        (.ciStillRunning, "Pipeline running"), (.requestedChanges, "Changes requested"),
    ]
    for (status, note) in cases {
        #expect(try mr(status).mergeBlocker == nil, "\(status)")
        #expect(try mr(status).mergeNote == note, "\(status)")
    }
}

@Test func gitlabUnresolvedDiscussionsAreAMergeWarning() throws {
    var p = try mr(.discussionsNotResolved)
    #expect(p.mergeWarnings == ["Threads are unresolved"])
    let open = ReviewThreadInfo(isResolved: false, firstComment: CommentInfo(author: "rita", isBot: false, body: "?"))
    let done = ReviewThreadInfo(isResolved: true, firstComment: CommentInfo(author: "rita", isBot: false, body: "ok"))
    p.threads = [open, done]
    #expect(p.mergeWarnings == ["1 thread is unresolved"])
    p.threads = [open, open, done]
    #expect(p.mergeWarnings == ["2 threads are unresolved"])
    #expect(try mr(.mergeable).mergeWarnings.isEmpty)
}

@Test func gitlabIgnoresGitHubsBranchProtectionState() throws {
    var p = try mr(.mergeable)
    p.mergeState = .blocked
    #expect(p.mergeBlocker == nil)
    #expect(p.mergeNote == nil)
}

@Test func gitlabOffersMergeAndSquashDefaultingToTheProjectsChoice() throws {
    var p = try mr(.mergeable)
    p.allowedMergeMethods = Set(MergeMethod.allCases)
    #expect(p.mergeMethods == [.merge, .squash])
    p.mergeMethod = .squash
    #expect(p.defaultMergeMethod == .squash)
    #expect(MergeMethod.merge.title(on: p.repo.forge) == "Merge")
    #expect(MergeMethod.squash.title(on: p.repo.forge) == "Squash and merge")
    #expect(MergeMethod.merge.title(on: .github) == "Create a merge commit")
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
