import Foundation

/// Assembles the prompt Explain PR hands to an agent or a chat.
public enum PromptBuilder {
    public static let maxDiffChars = 60_000

    /// "Explain PR": a walkthrough of the whole PR, whatever the item is. Read-only, so it never asks for edits.
    /// `inWorktree` is true when an agent starts in the PR's worktree (iTerm); false for a prompt pasted into a chat.
    public static func explainPRPrompt(for pr: PullRequest, diff: String?, inWorktree: Bool) -> String {
        var s = """
            Explain PR \(pr.ref) in \(pr.repo.fullName) to me: "\(pr.title)"
            Author: \(pr.author) · branch \(pr.headRef) · head \(pr.headSha.prefix(10))
            \(pr.url.absoluteString)

            """
        if let summary = pr.summary { s += "\n## Description (summary)\n\(summary)\n" }
        if let diff, !diff.isEmpty { s += diffSection(diff) }
        let whereYouAre =
            inWorktree
            ? "You're in a git worktree on branch \(pr.headRef), already up to date. Read the code around the changes "
                + "as needed, and `\(pr.repo.forge.cli("view", pr.number))` for the full description and discussion."
            : "Work from the description and diff above."
        s += """

            ## Task
            \(whereYouAre)
            1. What this PR does and why, in 2–4 sentences.
            2. Walk me through the changes, most important first: what each part does and how they fit together.
            3. Risks: anything that looks wrong, untested, or likely to break something else.
            4. What I should check or ask the author before approving.
            Don't edit files, commit or push: this is to understand the PR.

            """
        return s
    }

    static func diffSection(_ diff: String) -> String {
        guard diff.count > maxDiffChars else { return "\n## PR diff\n```diff\n\(diff)\n```\n" }
        let note = " (first \(maxDiffChars) of \(diff.count) characters)"
        return "\n## PR diff\(note)\n```diff\n\(diff.prefix(maxDiffChars))\n```\n"
    }
}
