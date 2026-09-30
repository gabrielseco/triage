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

    /// `viewer` is the signed-in login: their own review comments don't count as something new. `isNew` says the
    /// PR was opened since Triage started watching its repo and hasn't been dismissed yet (`SeenPRs`).
    public static func classify(
        _ pr: PullRequest, viewer: String? = nil, isNew: Bool = false
    ) -> (items: [AttentionItem], stats: PRStats) {
        var stats = PRStats(pendingChecks: pr.checks.filter { $0.state == .pending }.count)
        let open = pr.threads.filter { !$0.isResolved && !$0.isOutdated }

        var items = [
            ciFailure(pr), mergeConflict(pr), changesRequested(pr), reviewThreads(pr, open: open, viewer: viewer),
        ]
        .compactMap { $0 }
        items += botFindings(pr, open: open, noise: &stats.noiseComments)
        let request = reviewRequested(pr, viewer: viewer)
        if items.isEmpty, request == nil, let quiet = readyToMerge(pr) ?? awaitingChecks(pr) ?? awaitingReview(pr) {
            items.append(quiet)
        }
        if let request {
            items.append(request)
        } else if isNew, let new = newPR(pr, viewer: viewer) {
            items.append(new)
        }
        return (items, stats)
    }

    // MARK: - Rules (one item per rule per PR)

    static func ciFailure(_ pr: PullRequest) -> AttentionItem? {
        let failed = pr.checks.filter { $0.state == .failure }
        guard !failed.isEmpty else { return nil }
        let names = failed.map(\.name)
        let more = failed.count > 3 ? "…" : ""
        return AttentionItem(
            id: "\(pr.id)|ci|\(pr.headSha)",
            kind: .ciFailure,
            severity: pr.isDraft ? .medium : .high,
            pr: pr,
            headline: failed.count == 1
                ? "\(names[0]) is failing"
                : "\(failed.count) checks failing: \(names.prefix(3).joined(separator: ", "))\(more)",
            evidence: failed.map {
                Evidence(title: $0.name, detail: $0.summary, url: $0.url, checkRunID: $0.checkRunID)
            }
        )
    }

    static func mergeConflict(_ pr: PullRequest) -> AttentionItem? {
        guard pr.mergeable == .conflicting else { return nil }
        return AttentionItem(
            id: "\(pr.id)|conflict|\(pr.headSha)",
            kind: .mergeConflict,
            severity: .high,
            pr: pr,
            headline: "Conflicts with the base branch",
            evidence: [Evidence(title: "Branch \(pr.headRef) needs a rebase or merge", url: pr.url)]
        )
    }

    static func changesRequested(_ pr: PullRequest) -> AttentionItem? {
        guard pr.reviewDecision == .changesRequested else { return nil }
        return AttentionItem(
            id: "\(pr.id)|changes|\(pr.headSha)",
            kind: .changesRequested,
            severity: .high,
            pr: pr,
            headline: "A reviewer requested changes",
            evidence: [Evidence(title: "Review decision: changes requested", url: pr.url)]
        )
    }

    /// All open threads started by humans collapse into one item.
    static func reviewThreads(_ pr: PullRequest, open: [ReviewThreadInfo], viewer: String?) -> AttentionItem? {
        let human = open.filter { !$0.firstComment.isBot }
        guard let first = human.first else { return nil }
        return AttentionItem(
            id: reviewThreadsID(pr, viewer: viewer),
            kind: .reviewThreads,
            severity: .medium,
            pr: pr,
            headline: human.count == 1
                ? "\(first.firstComment.author) left an unresolved comment"
                : "\(human.count) unresolved review threads",
            evidence: human.map(threadEvidence)
        )
    }

    /// Changes when someone other than the viewer says something new (a new thread or a reply), not when a
    /// thread is resolved or goes outdated, or when the viewer replies, so a dismissed item only comes back
    /// for new conversation. Built from every human thread, resolved ones included, since the set of open
    /// ones shrinks as they're resolved.
    static func reviewThreadsID(_ pr: PullRequest, viewer: String?) -> String {
        let others = pr.threads.filter { !$0.firstComment.isBot }.flatMap(\.comments)
            .filter { !$0.isBot && $0.author != viewer }
        let newest = others.max { $0.createdAt < $1.createdAt }
        return "\(pr.id)|threads|\(newest?.url?.absoluteString ?? "")"
    }

    struct BotEntry {
        let date: Date
        let evidence: Evidence
        let body: String
        let url: URL?
    }

    /// Comments + open threads from bots that aren't noise, one item per bot. Noise is counted instead.
    static func botFindings(_ pr: PullRequest, open: [ReviewThreadInfo], noise: inout Int) -> [AttentionItem] {
        var byBot: [String: [BotEntry]] = [:]
        func add(_ author: String, _ entry: BotEntry) {
            let login = normalizedLogin(author)
            if noiseBots.contains(login) { noise += 1 } else { byBot[login, default: []].append(entry) }
        }
        for c in pr.comments where c.isBot {
            let evidence = Evidence(title: "Comment by \(c.author)", detail: c.body, url: c.url)
            add(c.author, BotEntry(date: c.createdAt, evidence: evidence, body: c.body, url: c.url))
        }
        for t in open where t.firstComment.isBot {
            let c = t.firstComment
            add(c.author, BotEntry(date: c.createdAt, evidence: threadEvidence(t), body: c.body, url: c.url))
        }
        return byBot.sorted { $0.key < $1.key }.map { login, entries in
            let sorted = entries.sorted { $0.date > $1.date }
            return AttentionItem(
                id: "\(pr.id)|bot|\(login)|\(sorted[0].url?.absoluteString ?? "\(sorted.count)")",
                kind: .botFinding,
                severity: sorted.map { botSeverity($0.body) }.max() ?? .low,
                pr: pr,
                headline: sorted.count == 1
                    ? "\(login): \(findingTitle(sorted[0].body) ?? "flagged something")"
                    : "\(login) left \(sorted.count) findings",
                evidence: sorted.map(\.evidence)
            )
        }
    }

    /// Someone asked the viewer for a review they haven't given yet. It says more than "waiting for review" or
    /// "new PR", so it takes their place. Keyed on the PR alone: a push doesn't bring back a dismissed request,
    /// but asking again after a review does, since the item goes away in between.
    static func reviewRequested(_ pr: PullRequest, viewer: String?) -> AttentionItem? {
        guard let viewer, pr.author != viewer, pr.requestedReviewers.contains(viewer) else { return nil }
        return AttentionItem(
            id: "\(pr.id)|review-requested",
            kind: .reviewRequested,
            severity: .medium,
            pr: pr,
            headline: "\(pr.author) is waiting on your review",
            evidence: [Evidence(title: pr.title, detail: pr.summary, url: pr.changesURL)]
        )
    }

    /// Someone else opened a PR: news even when nothing is wrong with it, since otherwise it would only show up
    /// as a passive "waiting for review". Added after the quiet items so it doesn't hide them. Not for the viewer's
    /// own PRs. Dependency bumps (renovate, dependabot) count too: they need a review and a merge like any other PR.
    static func newPR(_ pr: PullRequest, viewer: String?) -> AttentionItem? {
        guard pr.author != viewer else { return nil }
        return AttentionItem(
            id: "\(pr.id)|new",
            kind: .newPR,
            severity: .low,
            pr: pr,
            headline: "\(pr.isDraft ? "Draft opened" : "Opened") by \(pr.author)",
            evidence: [Evidence(title: pr.title, detail: pr.summary, url: pr.url)]
        )
    }

    /// Approved, green, mergeable, not a draft. Only offered when nothing else is open on the PR.
    static func readyToMerge(_ pr: PullRequest) -> AttentionItem? {
        let allGreen = !pr.checks.isEmpty && pr.checks.allSatisfy { $0.state == .success || $0.state == .neutral }
        guard !pr.isDraft, pr.reviewDecision == .approved, pr.mergeable == .mergeable, allGreen else { return nil }
        return AttentionItem(
            id: "\(pr.id)|ready|\(pr.headSha)",
            kind: .readyToMerge,
            severity: .info,
            pr: pr,
            headline: "Approved and green — ready to merge",
            evidence: [Evidence(title: "All \(pr.checks.count) checks passing", url: pr.url)]
        )
    }

    /// Open, not a draft, nothing wrong, not approved yet: the ball is with the reviewers. Like readyToMerge,
    /// only offered when nothing else is open on the PR. Includes repos that don't require reviews, where
    /// GitHub reports no review decision at all.
    static func awaitingReview(_ pr: PullRequest) -> AttentionItem? {
        guard !pr.isDraft, pr.reviewDecision != .approved else { return nil }
        let running = checksRunning(pr)
        return AttentionItem(
            id: "\(pr.id)|waiting|\(pr.headSha)",
            kind: .awaitingReview,
            severity: .info,
            pr: pr,
            headline: running.map { "Waiting for review · \($0)" } ?? "Waiting for review",
            evidence: [
                Evidence(
                    title: pr.reviewDecision == .reviewRequired
                        ? "A review is required before merging" : "No review yet",
                    url: pr.url)
            ]
        )
    }

    /// Approved, nothing failing, but not ready yet: checks still running, or GitHub hasn't worked out
    /// mergeability (common right after a push or a base-branch change). Otherwise an approved PR would
    /// vanish between "waiting for review" and "ready to merge".
    static func awaitingChecks(_ pr: PullRequest) -> AttentionItem? {
        let running = checksRunning(pr)
        guard !pr.isDraft, pr.reviewDecision == .approved, running != nil || pr.mergeable == .unknown else {
            return nil
        }
        return AttentionItem(
            id: "\(pr.id)|checks|\(pr.headSha)",
            kind: .awaitingChecks,
            severity: .info,
            pr: pr,
            headline: "Approved · \(running ?? "\(pr.repo.forge.name) is still checking mergeability")",
            evidence: pr.checks.filter { $0.state == .pending }.map {
                Evidence(title: "\($0.name) is running", url: $0.url)
            }
        )
    }

    /// "1 check running" / "3 checks running", or nil when nothing is pending.
    static func checksRunning(_ pr: PullRequest) -> String? {
        let n = pr.checks.filter { $0.state == .pending }.count
        return n == 0 ? nil : "\(n) check\(n == 1 ? "" : "s") running"
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
