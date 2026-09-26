import Foundation

/// Deterministic first pass: turns a PR snapshot into a handful of attention items.
/// Many raw events collapse into one item per (PR, kind) — ten comments from the same bot
/// or five failing jobs are one thing to look at, not ten.
public enum Classifier {
    /// Bots whose comments are status chatter, not findings. Matched on the normalized login.
    public static let noiseBots: Set<String> = [
        "codecov", "vercel", "netlify", "github-actions", "changeset-bot", "dependabot",
        "renovate", "sonarcloud", "linear", "cla-assistant", "height", "graphite-app",
    ]

    static let alarmWords = ["error", "fail", "vulnerab", "critical", "security", "breaking", "bug"]

    public static func normalizedLogin(_ login: String) -> String {
        login.lowercased().replacingOccurrences(of: "[bot]", with: "")
    }

    public static func classify(_ pr: PullRequest) -> (items: [AttentionItem], stats: PRStats) {
        var items: [AttentionItem] = []
        var stats = PRStats()

        // CI
        let failed = pr.checks.filter { $0.state == .failure }
        stats.pendingChecks = pr.checks.filter { $0.state == .pending }.count
        if !failed.isEmpty {
            let names = failed.map(\.name)
            items.append(
                AttentionItem(
                    id: "\(pr.id)|ci|\(pr.headSha)",
                    kind: .ciFailure,
                    severity: pr.isDraft ? .medium : .high,
                    pr: pr,
                    headline: failed.count == 1
                        ? "\(names[0]) is failing"
                        : "\(failed.count) checks failing: \(names.prefix(3).joined(separator: ", "))\(failed.count > 3 ? "…" : "")",
                    evidence: failed.map {
                        Evidence(title: $0.name, detail: $0.summary, url: $0.url, checkRunID: $0.checkRunID)
                    }
                ))
        }

        if pr.mergeable == .conflicting {
            items.append(
                AttentionItem(
                    id: "\(pr.id)|conflict|\(pr.headSha)",
                    kind: .mergeConflict,
                    severity: .high,
                    pr: pr,
                    headline: "Conflicts with the base branch",
                    evidence: [Evidence(title: "Branch \(pr.headRef) needs a rebase or merge", url: pr.url)]
                ))
        }

        if pr.reviewDecision == .changesRequested {
            items.append(
                AttentionItem(
                    id: "\(pr.id)|changes|\(pr.headSha)",
                    kind: .changesRequested,
                    severity: .high,
                    pr: pr,
                    headline: "A reviewer requested changes",
                    evidence: [Evidence(title: "Review decision: changes requested", url: pr.url)]
                ))
        }

        // Review threads: human vs bot
        let open = pr.threads.filter { !$0.isResolved && !$0.isOutdated }
        let humanThreads = open.filter { !$0.firstComment.isBot }
        if !humanThreads.isEmpty {
            let latest = humanThreads.max { $0.firstComment.createdAt < $1.firstComment.createdAt }!
            items.append(
                AttentionItem(
                    id: "\(pr.id)|threads|\(latest.firstComment.url?.absoluteString ?? "\(humanThreads.count)")",
                    kind: .reviewThreads,
                    severity: .medium,
                    pr: pr,
                    headline: humanThreads.count == 1
                        ? "\(latest.firstComment.author) left an unresolved comment"
                        : "\(humanThreads.count) unresolved review threads",
                    evidence: humanThreads.map(threadEvidence)
                ))
        }

        // Bot findings: comments + review threads from bots that aren't noise, grouped per bot.
        var byBot: [String: [(date: Date, evidence: Evidence, body: String, url: URL?)]] = [:]
        for c in pr.comments where c.isBot {
            let login = normalizedLogin(c.author)
            if noiseBots.contains(login) { stats.noiseComments += 1; continue }
            byBot[login, default: []].append(
                (c.createdAt, Evidence(title: "Comment by \(c.author)", detail: c.body, url: c.url), c.body, c.url))
        }
        for t in open where t.firstComment.isBot {
            let login = normalizedLogin(t.firstComment.author)
            if noiseBots.contains(login) { stats.noiseComments += 1; continue }
            byBot[login, default: []].append(
                (t.firstComment.createdAt, threadEvidence(t), t.firstComment.body, t.firstComment.url))
        }
        for (login, entries) in byBot.sorted(by: { $0.key < $1.key }) {
            let sorted = entries.sorted { $0.date > $1.date }
            items.append(
                AttentionItem(
                    id: "\(pr.id)|bot|\(login)|\(sorted[0].url?.absoluteString ?? "\(sorted.count)")",
                    kind: .botFinding,
                    severity: sorted.map { botSeverity($0.body) }.max() ?? .low,
                    pr: pr,
                    headline: sorted.count == 1
                        ? "\(login): \(findingTitle(sorted[0].body) ?? "flagged something")"
                        : "\(login) left \(sorted.count) findings",
                    evidence: sorted.map(\.evidence)
                ))
        }

        // Ready to merge: approved, green, mergeable, nothing else open.
        let allGreen = !pr.checks.isEmpty && pr.checks.allSatisfy { $0.state == .success || $0.state == .neutral }
        if items.isEmpty, !pr.isDraft, pr.reviewDecision == .approved, pr.mergeable == .mergeable, allGreen {
            items.append(
                AttentionItem(
                    id: "\(pr.id)|ready|\(pr.headSha)",
                    kind: .readyToMerge,
                    severity: .info,
                    pr: pr,
                    headline: "Approved and green — ready to merge",
                    evidence: [Evidence(title: "All \(pr.checks.count) checks passing", url: pr.url)]
                ))
        }

        return (items, stats)
    }

    /// Review bots (Cursor Bugbot, CodeRabbit, …) often label findings "High Severity" etc.; trust
    /// that when present, otherwise fall back to keyword sniffing.
    static func botSeverity(_ body: String) -> Severity {
        let b = body.lowercased()
        if b.contains("critical severity") || b.contains("high severity") { return .high }
        if b.contains("medium severity") { return .medium }
        if b.contains("low severity") { return .low }
        return alarmWords.contains { b.contains($0) } ? .medium : .low
    }

    /// First markdown heading (or failing that, first line) of a bot comment, e.g. Bugbot's
    /// "### GBR schema pin exceeds latest version".
    static func findingTitle(_ body: String) -> String? {
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && !$0.hasPrefix("<!--")
        }
        let line = lines.first { $0.hasPrefix("#") } ?? lines.first
        guard let line else { return nil }
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "#* ").union(.whitespaces))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(90))
    }

    static func threadEvidence(_ t: ReviewThreadInfo) -> Evidence {
        var title = t.firstComment.author
        if let path = t.path { title += " on \(path)\(t.line.map { ":\($0)" } ?? "")" }
        if t.commentCount > 1 { title += " (\(t.commentCount) comments)" }
        return Evidence(title: title, detail: t.firstComment.body, url: t.firstComment.url)
    }
}
