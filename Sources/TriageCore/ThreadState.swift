import Foundation

/// Where a review thread stands: still waiting, a fix was reported in the PR, or resolved.
public enum ThreadState: Hashable, Sendable {
    case open
    /// Someone said which commit of the PR fixes it. `commit` is that commit's full SHA.
    case fixReported(commit: String)
    case resolved(by: String?)
    /// You judged the bot or reviewer wrong. Kept on this Mac only: the forge still has the thread open.
    case falsePositive

    /// The text a row shows; nil for an open thread, which needs no label.
    public var label: String? {
        switch self {
        case .open: nil
        case .fixReported(let commit): "Fix reported · \(Self.shortSha(commit))"
        case .resolved: "Resolved"
        case .falsePositive: "False positive"
        }
    }

    public static func shortSha(_ sha: String) -> String { String(sha.prefix(7)) }
}

public enum ThreadStates {
    /// Resolved wins. Otherwise a reply after the opening comment from a person (not a bot) that links or names
    /// a commit of the PR reports a fix, unless a bot spoke again after it: then the bot still sees a problem and
    /// the thread is open. A commit that isn't in the PR (another repo, an older branch) reports nothing, and a
    /// fix is never guessed without one.
    public static func state(of thread: ReviewThreadInfo, prCommits: [String]) -> ThreadState {
        if thread.isResolved { return .resolved(by: thread.resolvedBy) }
        let replies = thread.comments.dropFirst().sorted { $0.createdAt < $1.createdAt }
        guard
            let fix = replies.last(where: { !$0.isBot && reportedCommit(in: $0.body, prCommits: prCommits) != nil }),
            let commit = reportedCommit(in: fix.body, prCommits: prCommits)
        else { return .open }
        if replies.contains(where: { $0.isBot && $0.createdAt > fix.createdAt }) { return .open }
        return .fixReported(commit: commit)
    }

    public static func states(_ threads: [ReviewThreadInfo], prCommits: [String]) -> [ThreadState] {
        threads.map { state(of: $0, prCommits: prCommits) }
    }

    /// The full SHA of the last commit of the PR that the text names, by commit link or by (abbreviated) SHA.
    static func reportedCommit(in body: String, prCommits: [String]) -> String? {
        let commits = prCommits.map { $0.lowercased() }
        var found: String?
        for token in hexTokens(in: body) {
            if let match = commits.first(where: { $0.hasPrefix(token) }) { found = match }
        }
        return found
    }

    /// Runs of 7 to 40 hex digits not glued to other letters or digits, so `/commit/abc1234` counts and a word
    /// that merely contains hex letters does not.
    private static func hexTokens(in text: String) -> [String] {
        let pattern = #"(?<![0-9A-Za-z])[0-9a-fA-F]{7,40}(?![0-9A-Za-z])"#
        var tokens: [String] = []
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: pattern, options: .regularExpression, range: range) {
            tokens.append(text[r].lowercased())
            range = r.upperBound..<text.endIndex
        }
        return tokens
    }
}

extension PullRequest {
    /// A thread's state against this PR's commits (the head included).
    public func state(of thread: ReviewThreadInfo) -> ThreadState {
        ThreadStates.state(of: thread, prCommits: commitShas + [headSha].filter { !$0.isEmpty })
    }
}
