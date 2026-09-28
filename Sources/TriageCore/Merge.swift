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
}

extension PullRequest {
    /// Why GitHub would refuse to merge this PR outright, or nil if it can be tried.
    public var mergeBlocker: String? {
        if isDraft { return "It's a draft" }
        if mergeable == .conflicting { return "It conflicts with the base branch" }
        return nil
    }

    /// Whether the viewer can approve it: someone else's PR, ready for review, not approved by them yet.
    /// GitHub doesn't let you approve your own PR.
    public func canBeApproved(by viewer: String?) -> Bool {
        guard let viewer else { return false }
        return author != viewer && !isDraft && !viewerApproved
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
        if mergeable == .unknown { w.append("GitHub is still checking mergeability") }
        return w
    }
}
