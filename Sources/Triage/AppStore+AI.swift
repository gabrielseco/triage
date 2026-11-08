import AppKit
import Foundation
import TriageCore

/// The Explain PR prompt: the PR's description and diff, for an agent or a chat.
extension AppStore {
    // MARK: - Explain PR

    /// Explain PR: the PR's description and diff, whatever the item is.
    func buildExplainPRPrompt(for pr: PullRequest, inWorktree: Bool) async -> String {
        var diff: String?
        if pr.repo.forge.capabilities.contains(.diff), let client = try? await forgeClient(pr.repo.forge) {
            diff = await client.diff(pr)
        }
        return PromptBuilder.explainPRPrompt(for: pr, diff: diff, inWorktree: inWorktree)
    }

    func copyExplainPRPrompt(for item: AttentionItem) async {
        actionStatus[item.id] = "Fetching the diff…"
        let text = await buildExplainPRPrompt(for: item.pr, inWorktree: false)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actionStatus[item.id] = "Copied the Explain PR prompt (\(text.count / 1000) KB) to the clipboard"
    }
}
