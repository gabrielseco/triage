import Foundation

public struct PromptContext: Sendable {
    public var checkOutputs: [(name: String, text: String)] = []
    public var diff: String?
    public init(checkOutputs: [(name: String, text: String)] = [], diff: String? = nil) {
        self.checkOutputs = checkOutputs
        self.diff = diff
    }
}

public enum PromptMode: Sendable {
    /// Sent to Claude from the app: explain and propose, no repo access.
    case explain
    /// Pasted into Claude Code inside a local checkout: allowed to fix.
    case claudeCode
    /// Started by "Fix in iTerm": the agent is already in a dedicated worktree on the PR branch.
    case handoff
}

/// Same idea as expenses-backend's get_*_prompt tools: assemble all the evidence into one prompt,
/// so the model (or the human) reasons over it without having to go fetch anything.
public enum PromptBuilder {
    /// Logs can be megabytes; the failure is almost always at the end.
    public static let logTailLines = 250
    public static let maxDiffChars = 60_000

    public static let systemPrompt = """
        You are a senior engineer triaging pull requests. You get the evidence for one problem on one PR. \
        Be concrete and brief: say what is wrong, why, and the smallest fix. If the evidence points to a \
        flaky or unrelated failure rather than this PR's change, say so and recommend a rerun instead of a code change.
        """

    public static func prompt(for item: AttentionItem, context: PromptContext, mode: PromptMode) -> String {
        let pr = item.pr
        var s = """
            You're on PR \(pr.ref) in \(pr.repo.fullName): "\(pr.title)"
            Author: \(pr.author) · branch \(pr.headRef) · head \(pr.headSha.prefix(10))
            \(pr.url.absoluteString)

            Problem: \(item.kind.title) — \(item.headline)

            """

        s += evidenceSection(item.evidence)
        s += context.checkOutputs.map { logSection(name: $0.name, text: $0.text) }.joined()
        if let diff = context.diff, !diff.isEmpty { s += diffSection(diff) }
        s += "\n## Task\n" + task(for: pr, mode: mode)
        return s
    }

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

    static func evidenceSection(_ evidence: [Evidence]) -> String {
        var s = "\n## Evidence\n"
        for e in evidence {
            s += "\n### \(e.title)\n"
            if let url = e.url { s += "\(url.absoluteString)\n" }
            if let d = e.detail, !d.isEmpty { s += "\n\(d)\n" }
        }
        return s
    }

    static func logSection(name: String, text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(logTailLines).joined(separator: "\n")
        let note = lines.count > logTailLines ? " (last \(logTailLines) of \(lines.count) lines)" : ""
        return "\n## Output of \(name)\(note)\n```\n\(tail)\n```\n"
    }

    static func diffSection(_ diff: String) -> String {
        guard diff.count > maxDiffChars else { return "\n## PR diff\n```diff\n\(diff)\n```\n" }
        let note = " (first \(maxDiffChars) of \(diff.count) characters)"
        return "\n## PR diff\(note)\n```diff\n\(diff.prefix(maxDiffChars))\n```\n"
    }

    static func task(for pr: PullRequest, mode: PromptMode) -> String {
        switch mode {
        case .explain:
            return """
                1. Explain the issue in 2–4 sentences.
                2. Classify it: real bug in this PR / flaky or infra / needs a human decision.
                3. Propose the fix. If it's a code change, give a unified diff against the files above.
                4. Draft a one-paragraph reply to post on the PR, if a reply is warranted.
                """
        case .claudeCode:
            let checkout = pr.repo.forge.cli("checkout", pr.number)
            return """
                Run `\(checkout)` in a checkout of \(pr.repo.fullName) if you aren't on the branch.
                1. Read the evidence above and the relevant code, and explain the issue.
                2. Propose a fix and wait for my go-ahead before editing.
                3. After I approve: make the change, run the relevant tests locally, commit, and push to \(pr.headRef).
                """
        case .handoff:
            return """
                You're in a git worktree dedicated to this PR, on branch \(pr.headRef), already up to date.
                1. Read the evidence above and the relevant code, and explain the issue.
                2. Propose a fix and wait for my go-ahead before editing.
                3. After I approve: make the change, run the relevant tests, commit, and push to \(pr.headRef).
                """
        }
    }
}
