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
        can(.approve, pr) && pr.canBeApproved(by: viewer(for: pr.repo.forge))
            && !approvedHeads.contains(Self.approvalKey(pr))
    }

    func approvePullRequest(_ item: AttentionItem) async {
        guard await sendApproval(item) else { return }
        actionStatus[item.id] = "Approved \(item.pr.ref)"
        await refresh()  // it may be ready to merge now
    }

    /// Posts the approval, with progress and errors in the item's status. Returns whether it went through.
    private func sendApproval(_ item: AttentionItem) async -> Bool {
        let pr = item.pr
        actionStatus[item.id] = "Approving \(pr.ref)…"
        do {
            try await approve(pr, with: try await forgeClient(pr.repo.forge))
            return true
        } catch {
            actionStatus[item.id] = "Couldn't approve \(pr.ref): \(error.localizedDescription)"
            return false
        }
    }

    /// Hides Approve at once (so it can't be sent twice), and brings it back if GitHub refuses.
    private func approve(_ pr: PullRequest, with client: any ForgeClient) async throws {
        let key = Self.approvalKey(pr)
        approvedHeads.insert(key)
        do {
            try await client.approve(pr)
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
        await mutate(item, doing: "Merging", failed: "merge") { try await $0.merge(pr) }
    }

    // MARK: - Close

    func closePullRequest(_ item: AttentionItem) async {
        let pr = item.pr
        await mutate(item, doing: "Closing", failed: "close") { try await $0.close(pr) }
    }

    /// Runs a change that takes the PR out of the open list, then hides it.
    private func mutate(
        _ item: AttentionItem, doing: String, failed: String, _ change: (any ForgeClient) async throws -> Void
    ) async {
        let pr = item.pr
        actionStatus[item.id] = "\(doing) \(pr.ref)…"
        do {
            try await change(try await forgeClient(pr.repo.forge))
        } catch {
            actionStatus[item.id] = "Couldn't \(failed) \(pr.ref): \(error.localizedDescription)"
            return
        }
        actionStatus[item.id] = nil
        // Hide it now; a refresh already in flight may still return it as open.
        closedPRIDs.insert(pr.id)
        if selectedItem?.pr.id == pr.id { selection = visibleItems.first?.id }
    }
}
