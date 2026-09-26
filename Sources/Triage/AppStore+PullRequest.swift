import Foundation
import TriageCore

/// Actions on the pull request itself rather than on one attention item.
extension AppStore {
    // MARK: - Close

    func closePullRequest(_ item: AttentionItem) async {
        let pr = item.pr
        actionStatus[item.id] = "Closing #\(pr.number)…"
        guard let token = await GitHubAuth.resolveToken() else {
            actionStatus[item.id] = GitHubError.noToken.localizedDescription
            return
        }
        do {
            try await GitHubClient(token: token).closePullRequest(pr.repo, number: pr.number)
        } catch {
            actionStatus[item.id] = "Couldn't close #\(pr.number): \(error.localizedDescription)"
            return
        }
        actionStatus[item.id] = nil
        // Hide it now; a refresh already in flight may still return it as open.
        closedPRIDs.insert(pr.id)
        if selectedItem?.pr.id == pr.id { selection = visibleItems.first?.id }
    }
}
