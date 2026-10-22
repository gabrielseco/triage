import Foundation

/// How a PR is merged. Raw values are GraphQL's `PullRequestMergeMethod`.
public enum MergeMethod: String, Sendable, CaseIterable {
    case merge = "MERGE", squash = "SQUASH", rebase = "REBASE"

    /// What the REST merge endpoint expects in `merge_method`.
    public var restValue: String { rawValue.lowercased() }

    public var title: String {
        switch self {
        case .merge: "Create a merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }

    /// The title as `forge` words it: GitLab's plain Merge may fast-forward, so it doesn't promise a merge commit.
    public func title(on forge: Forge) -> String {
        if case .gitlab = forge, self == .merge { return "Merge" }
        return title
    }
}

/// GitLab's `detailedMergeStatus`, the merge box's verdict. Only the values Triage words; others decode to nil.
public enum DetailedMergeStatus: String, Sendable, CaseIterable {
    case mergeable = "MERGEABLE", conflict = "CONFLICT", needRebase = "NEED_REBASE", draft = "DRAFT_STATUS"
    case checking = "CHECKING", unchecked = "UNCHECKED", preparing = "PREPARING"
    case notApproved = "NOT_APPROVED", discussionsNotResolved = "DISCUSSIONS_NOT_RESOLVED"
    case ciMustPass = "CI_MUST_PASS", ciStillRunning = "CI_STILL_RUNNING", requestedChanges = "REQUESTED_CHANGES"
}

/// GitHub's `MergeStateStatus`: whether the merge box would let the PR in, branch protection included.
public enum MergeState: String, Sendable, CaseIterable {
    case clean = "CLEAN", blocked = "BLOCKED", behind = "BEHIND", dirty = "DIRTY", draft = "DRAFT"
    case hasHooks = "HAS_HOOKS", unstable = "UNSTABLE", unknown = "UNKNOWN"
}

extension PullRequest {
    /// Why GitHub would refuse to merge this PR, short enough to sit beside the Merge button, or nil if it can be
    /// tried. Failing checks, missing reviews and an out-of-date branch only block when branch protection says so
    /// (`mergeState`), and not for an admin who can merge past it.
    public var mergeBlocker: String? {
        if case .gitlab = repo.forge { return gitlabMergeBlocker }
        if isDraft { return "Draft" }
        if mergeable == .conflicting { return "Merge conflicts" }
        switch mergeState {
        case .blocked where !viewerCanMergeAsAdmin: return mergeCaution ?? "Blocked by branch protection"
        case .behind where !viewerCanMergeAsAdmin: return "Branch out of date"
        default: return nil
        }
    }

    /// What to show beside the Merge button: the blocker, else the main reason to think twice (which doesn't
    /// disable it). Nil when the PR is clear to merge.
    public var mergeNote: String? {
        if let mergeBlocker { return mergeBlocker }
        if case .gitlab = repo.forge { return gitlabMergeCaution ?? mergeCaution }
        if mergeState == .behind { return "Branch out of date" }
        return mergeCaution ?? (mergeState == .blocked ? "Blocked by branch protection" : nil)
    }

    /// What GitLab can't merge at all: a draft, conflicts, a branch to rebase, or a status it hasn't worked out.
    var gitlabMergeBlocker: String? {
        if isDraft || detailedMergeStatus == .draft { return "Draft" }
        switch detailedMergeStatus {
        case .conflict: return "Merge conflicts"
        case .needRebase: return "Branch needs a rebase"
        case .checking, .unchecked, .preparing: return "GitLab is checking mergeability"
        default: return mergeable == .conflicting ? "Merge conflicts" : nil
        }
    }

    /// What GitLab's merge checks wait on. It doesn't disable Merge: GitLab says no itself if the project
    /// enforces it, and the note says why beforehand.
    var gitlabMergeCaution: String? {
        switch detailedMergeStatus {
        case .notApproved: "Approval required"
        case .ciMustPass: "Pipeline must succeed"
        case .ciStillRunning: "Pipeline running"
        case .discussionsNotResolved: "Unresolved threads"
        case .requestedChanges: "Changes requested"
        default: nil
        }
    }

    /// The checks or reviews in the way, short: what branch protection blocks on when it does.
    var mergeCaution: String? {
        if checks.contains(where: { $0.state == .failure }) { return "Checks failing" }
        if reviewDecision == .changesRequested { return "Changes requested" }
        if reviewDecision == .reviewRequired { return "Review required" }
        if checks.contains(where: { $0.state == .pending }) { return "Checks running" }
        return nil
    }

    /// The methods the repo allows and the forge has, in GitHub's menu order.
    public var mergeMethods: [MergeMethod] {
        repo.forge.mergeMethods.filter(allowedMergeMethods.contains)
    }

    /// What the primary Merge click uses: the viewer's default, or the first allowed method if that's turned off.
    public var defaultMergeMethod: MergeMethod {
        mergeMethods.contains(mergeMethod) ? mergeMethod : mergeMethods.first ?? mergeMethod
    }

    /// Whether the viewer can approve it: someone else's PR, ready for review, not approved by them yet.
    /// GitHub doesn't let you approve your own PR.
    public func canBeApproved(by viewer: String?) -> Bool {
        guard let viewer else { return false }
        return author != viewer && !isDraft && !approvedBy.contains(viewer)
    }

    /// Reasons to think twice before merging, which branch protection may or may not enforce.
    public var mergeWarnings: [String] {
        var w: [String] = []
        let failing = checks.filter { $0.state == .failure }.count
        let running = checks.filter { $0.state == .pending }.count
        if failing > 0 { w.append("\(failing) check\(failing == 1 ? " is" : "s are") failing") }
        if running > 0 { w.append("\(running) check\(running == 1 ? " is" : "s are") still running") }
        switch reviewDecision {
        case .changesRequested: w.append("A reviewer requested changes")
        case .reviewRequired: w.append("It isn't approved yet")
        case .approved, .none: break
        }
        if mergeable == .unknown { w.append("\(repo.forge.name) is still checking mergeability") }
        return w
    }
}
