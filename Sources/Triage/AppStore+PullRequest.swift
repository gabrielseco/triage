import Foundation
import TriageCore

/// Merge or close: asked for from the item detail or the Pull Request menu, confirmed in the item detail.
struct PRConfirmation: Identifiable {
    enum Action { case merge, close }
    let action: Action
    let item: AttentionItem
    var id: String { "\(action)|\(item.id)" }
}

/// Actions on the pull request itself rather than on one attention item.
extension AppStore {
    // MARK: - Merge

    func mergePullRequest(_ item: AttentionItem) async {
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
