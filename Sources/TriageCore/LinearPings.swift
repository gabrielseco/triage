import Foundation

/// A Linear thread where someone is waiting on me: an @-mention, or a reply in a thread I commented in.
public struct LinearPing: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case mentioned, threadReply

        /// For the sidebar row, which lists many.
        public var title: String {
            switch self {
            case .mentioned: "Mentioned"
            case .threadReply: "Thread replies"
            }
        }

        public var symbol: String {
            switch self {
            case .mentioned: "at"
            case .threadReply: "arrowshape.turn.up.left"
            }
        }

        /// What happened, after the person's name: "Alice mentioned you".
        public var verb: String {
            switch self {
            case .mentioned: "mentioned you"
            case .threadReply: "replied in your thread"
            }
        }
    }

    /// `linear:<ISSUE-123>:<thread root comment id, or "issue">:<latest ping>`, so a dismissed thread comes back
    /// only when there's a newer ping.
    public var id: String
    public var kind: Kind
    public var issueKey: String
    public var issueTitle: String
    /// Who pinged, or nil for an integration.
    public var author: String?
    public var authorAvatar: URL?
    /// The start of the comment that pinged me, or the issue title for a description mention.
    public var excerpt: String
    /// The whole comment, for the detail view; the issue title for a description mention.
    public var body: String
    /// The comment itself, so Open lands on it.
    public var url: URL
    public var pingedAt: Date
    /// Groups a thread's notifications together: `<ISSUE-123>:<thread root comment id, or "issue">`.
    public var threadID: String

    /// "Alice mentioned you", or "Someone" for an integration.
    public var headline: String { "\(author ?? "Someone") \(kind.verb)" }

    public static let idPrefix = "linear:"

    /// Dismissed and snoozed ids are shared with PR items; each source prunes only its own.
    public static func isPingID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }
}

public enum LinearPings {
    /// Notifications → the threads still waiting on my answer, newest ping first. `now` is passed in so tests
    /// can pin the 30-day window and Linear's snoozes.
    public static func classify(_ notifications: [LinearNotification], now: Date) -> [LinearPing] {
        let cutoff = now.addingTimeInterval(-LinearClient.window)
        let open = notifications.filter { n in
            n.createdAt > cutoff && kind(of: n) != nil && !(n.actor?.isMe ?? false)
                && !closedBefore(n) && !isResolved(n)
                && (n.snoozedUntilAt ?? .distantPast) <= now
        }
        let threads = Dictionary(grouping: open, by: threadID)
        return threads.compactMap { threadID, pings -> LinearPing? in
            guard let latest = pings.max(by: { $0.createdAt < $1.createdAt }), let kind = kind(of: latest),
                !answered(latest)
            else { return nil }
            return LinearPing(
                id: "\(LinearPing.idPrefix)\(threadID):\(latest.comment?.id ?? latest.id)", kind: kind,
                issueKey: latest.issue.identifier, issueTitle: latest.issue.title,
                author: latest.actor?.name, authorAvatar: latest.actor?.avatarUrl,
                excerpt: latest.comment.map { excerpt($0.body) } ?? latest.issue.title,
                body: latest.comment?.body ?? latest.issue.title,
                url: latest.comment?.url ?? latest.issue.url, pingedAt: latest.createdAt, threadID: threadID)
        }
        .sorted { ($0.pingedAt, $0.id) > ($1.pingedAt, $1.id) }
    }

    /// After a Linear fetch, forgets hidden pings that are no longer open (answered, or a newer ping replaced
    /// them). PR item ids are left alone: the PR refresh prunes those.
    public static func pruneHidden(_ ids: Set<String>, live: Set<String>) -> Set<String> {
        ids.filter { !LinearPing.isPingID($0) || live.contains($0) }
    }

    /// Done, canceled or duplicate: nothing left to answer.
    static let closedStates: Set = ["completed", "canceled", "duplicate"]

    /// The issue was closed after the ping, which settles it. A ping that comes after the close (someone
    /// following up on a Done issue) is new and still waits on me. No close time: treat it as closed before.
    static func closedBefore(_ n: LinearNotification) -> Bool {
        guard closedStates.contains(n.issue.state.type) else { return false }
        guard let closedAt = n.issue.completedAt ?? n.issue.canceledAt else { return true }
        return n.createdAt <= closedAt
    }

    /// Mentions always count; a reply only in a thread I started or answered in. A new top-level comment on
    /// an issue I merely follow is dropped.
    static func kind(of n: LinearNotification) -> LinearPing.Kind? {
        switch n.category {
        case "mentions": return .mentioned
        case "commentsAndReplies":
            guard let parent = n.comment?.parent else { return nil }
            let mine = (parent.user?.isMe ?? false) || !parent.children.nodes.isEmpty
            return mine ? .threadReply : nil
        default: return nil
        }
    }

    /// The thread a ping belongs to: a reply's parent, a top-level comment itself, or the issue description.
    static func threadID(_ n: LinearNotification) -> String {
        "\(n.issue.identifier):\(n.comment.map { $0.parent?.id ?? $0.id } ?? "issue")"
    }

    static func isResolved(_ n: LinearNotification) -> Bool {
        guard let comment = n.comment else { return false }
        if let parent = comment.parent { return parent.resolvedAt != nil }
        return comment.resolvedAt != nil
    }

    /// I commented in the thread after the ping. A description mention counts any comment of mine on the issue.
    static func answered(_ n: LinearNotification) -> Bool {
        let mine: [LinearNotification.Mine]
        if let comment = n.comment {
            mine = (comment.parent?.children ?? comment.children).nodes
        } else {
            mine = n.issue.comments.nodes
        }
        return mine.contains { $0.createdAt > n.createdAt }
    }

    /// The first non-empty line, short enough for a row or a notification.
    static func excerpt(_ body: String, limit: Int = 140) -> String {
        let line =
            body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
