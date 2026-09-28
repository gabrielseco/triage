import Foundation
import TriageCore

/// Merge (optionally approving first) or close: asked for from the item detail or the Pull Request menu, confirmed in the item detail.
struct PRConfirmation: Identifiable {
    enum Action { case merge, close }
    let action: Action
    let item: AttentionItem
    var id: String { "\(action)|\(item.id)" }
}

/// Actions on the pull request itself rather than on one attention item.
extension AppStore {
    // MARK: - Approve

    /// Someone else's PR you haven't approved, counting approvals sent since the last refresh.
    func canApprove(_ pr: PullRequest) -> Bool {
        pr.canBeApproved(by: viewer) && !approvedHeads.contains(Self.approvalKey(pr))
    }

    func approvePullRequest(_ item: AttentionItem) async {
        guard await sendApproval(item) else { return }
        actionStatus[item.id] = "Approved #\(item.pr.number)"
        await refresh()  // it may be ready to merge now
    }

    /// Posts the approval, with progress and errors in the item's status. Returns whether it went through.
    private func sendApproval(_ item: AttentionItem) async -> Bool {
        let pr = item.pr
        actionStatus[item.id] = "Approving #\(pr.number)…"
        guard let token = await GitHubAuth.resolveToken() else {
            actionStatus[item.id] = GitHubError.noToken.localizedDescription
            return false
        }
        do {
            try await approve(pr, with: GitHubClient(token: token))
            return true
        } catch {
            actionStatus[item.id] = "Couldn't approve #\(pr.number): \(error.localizedDescription)"
            return false
        }
    }

    /// Hides Approve at once (so it can't be sent twice), and brings it back if GitHub refuses.
    private func approve(_ pr: PullRequest, with gh: GitHubClient) async throws {
        let key = Self.approvalKey(pr)
        approvedHeads.insert(key)
        do {
            try await gh.approvePullRequest(pr.repo, number: pr.number, sha: pr.headSha)
        } catch {
            approvedHeads.remove(key)
            throw error
        }
    }

    /// Per head commit: a push after approving asks for a fresh look.
    private static func approvalKey(_ pr: PullRequest) -> String { "\(pr.id)@\(pr.headSha)" }

    // MARK: - Merge

    /// `approvingFirst`: approve as the viewer, then merge, for someone else's PR you haven't approved.
    /// Two steps, so a failed merge doesn't read as a failed approval.
    func mergePullRequest(_ item: AttentionItem, approvingFirst: Bool = false) async {
        if approvingFirst, !(await sendApproval(item)) { return }
        let pr = item.pr
        await mutate(item, doing: "Merging", failed: "merge") { gh in
            try await gh.mergePullRequest(pr.repo, number: pr.number, sha: pr.headSha, method: pr.mergeMethod)
        }
    }

    // MARK: - Close

    func closePullRequest(_ item: AttentionItem) async {
        let pr = item.pr
        await mutate(item, doing: "Closing", failed: "close") { gh in
            try await gh.closePullRequest(pr.repo, number: pr.number)
        }
    }

    /// Runs a change that takes the PR out of the open list, then hides it.
    private func mutate(
        _ item: AttentionItem, doing: String, failed: String, _ change: (GitHubClient) async throws -> Void
    ) async {
        let pr = item.pr
        actionStatus[item.id] = "\(doing) #\(pr.number)…"
        guard let token = await GitHubAuth.resolveToken() else {
            actionStatus[item.id] = GitHubError.noToken.localizedDescription
            return
        }
        do {
            try await change(GitHubClient(token: token))
        } catch {
            actionStatus[item.id] = "Couldn't \(failed) #\(pr.number): \(error.localizedDescription)"
            return
        }
        actionStatus[item.id] = nil
        // Hide it now; a refresh already in flight may still return it as open.
        closedPRIDs.insert(pr.id)
        if selectedItem?.pr.id == pr.id { selection = visibleItems.first?.id }
    }
}
