import Foundation

/// Explain, fix and report on a review thread through Workbench. Triage asks `workbench explain-thread`, shows the
/// reasoning and the proposed fix, and only when you press Fix does `workbench fix-thread` push a commit and
/// `workbench reply-thread` say so on the thread. Resolving is a separate, explicit action on the forge.

/// One review thread of one PR, at the head Triage last saw.
public struct ThreadRef: Hashable, Sendable {
    public var repo: RepoRef
    public var number: Int
    public var threadID: String
    public var head: String

    public init(repo: RepoRef, number: Int, threadID: String, head: String) {
        self.repo = repo
        self.number = number
        self.threadID = threadID
        self.head = head
    }
}

/// What Workbench says about a thread: why it was raised, and what change would answer it.
public struct ThreadExplanation: Codable, Hashable, Sendable {
    public var reasoning: String
    public var proposedFix: String

    public init(reasoning: String, proposedFix: String) {
        self.reasoning = reasoning
        self.proposedFix = proposedFix
    }
}

/// A kept explanation: the head it was written for decides whether it still applies.
public struct ThreadExplanationRecord: Codable, Hashable, Sendable {
    public var head: String
    public var explanation: ThreadExplanation
    public var at: Date

    public init(head: String, explanation: ThreadExplanation, at: Date) {
        self.head = head
        self.explanation = explanation
        self.at = at
    }
}

/// What a thread shows under its Explain button.
public enum ThreadExplanationStatus: Hashable, Sendable {
    case none
    case running
    case current(ThreadExplanation, at: Date)
    /// Written for an older head: the PR has moved since, so the reasoning may no longer hold.
    case stale(ThreadExplanation, at: Date)

    public var explanation: ThreadExplanation? {
        switch self {
        case .current(let e, _), .stale(let e, _): e
        case .none, .running: nil
        }
    }
}

/// What Triage keeps about threads on this Mac: explanations by thread id (each knowing its head SHA), and the
/// threads you dismissed as false positives. Neither is ever sent to the forge.
public struct ThreadTriage: Codable, Equatable, Sendable {
    public private(set) var explanations: [String: ThreadExplanationRecord] = [:]
    public private(set) var dismissed: Set<String> = []

    public init() {}

    public mutating func store(_ explanation: ThreadExplanation, for thread: ThreadRef, at: Date = Date()) {
        explanations[thread.threadID] = ThreadExplanationRecord(head: thread.head, explanation: explanation, at: at)
    }

    /// The explanation for a thread, stale once the PR's head is not the one it was written for.
    public func status(of threadID: String, head: String, running: Bool = false) -> ThreadExplanationStatus {
        if running { return .running }
        guard let record = explanations[threadID] else { return .none }
        let moved = ExplainPR.head7(record.head) != ExplainPR.head7(head)
        return moved ? .stale(record.explanation, at: record.at) : .current(record.explanation, at: record.at)
    }

    public mutating func dismissAsFalsePositive(_ threadID: String) { dismissed.insert(threadID) }
    public mutating func restore(_ threadID: String) { dismissed.remove(threadID) }

    /// The state a thread shows: what the forge says, except that an open thread you called a false positive shows
    /// that. A resolved thread, or one with a reported fix, keeps the forge's word.
    public func state(of thread: ReviewThreadInfo, in pr: PullRequest) -> ThreadState {
        let forge = pr.state(of: thread)
        guard case .open = forge, let id = thread.id, dismissed.contains(id) else { return forge }
        return .falsePositive
    }
}

/// The three things Workbench does for a thread. Behind a protocol so the app can run on a fake in mock mode.
public protocol ThreadWorkbench: Sendable {
    func explain(_ thread: ThreadRef) async throws -> ThreadExplanation
    /// Applies the fix, pushes it, and returns the pushed commit's full SHA.
    func fix(_ thread: ThreadRef) async throws -> String
    /// Posts `body` as a reply on the thread.
    func reply(_ thread: ThreadRef, body: String) async throws
}

public enum ThreadWorkbenchError: LocalizedError, Equatable {
    case failed(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .unreadable(let out): "Workbench's answer wasn't what Triage expects: \(out)"
        }
    }
}

/// The real thing: `workbench explain-thread|fix-thread|reply-thread --pr <n> --thread <id>`, run in the local clone.
/// `explain-thread` and `fix-thread` print one JSON object (`{"reasoning", "proposed_fix"}` and `{"commit"}`).
public struct CLIThreadWorkbench: ThreadWorkbench {
    public var workbench: String
    public var checkout: String

    public init(workbench: String, checkout: String) {
        self.workbench = workbench
        self.checkout = checkout
    }

    static func arguments(_ verb: String, _ thread: ThreadRef, extra: [String] = []) -> [String] {
        [verb, "--pr", String(thread.number), "--thread", thread.threadID] + extra
    }

    func run(_ arguments: [String]) async throws -> String {
        let result: Subprocess.Output
        do {
            result = try await Subprocess.run(workbench, arguments, directory: checkout)
        } catch {
            throw ThreadWorkbenchError.failed("Couldn't start Workbench: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            throw ThreadWorkbenchError.failed(
                ExplainPR.failureMessage(stderr: result.stderr, status: result.status))
        }
        return result.trimmedStdout
    }

    public func explain(_ thread: ThreadRef) async throws -> ThreadExplanation {
        try Self.parseExplanation(try await run(Self.arguments("explain-thread", thread)))
    }

    public func fix(_ thread: ThreadRef) async throws -> String {
        try Self.parseCommit(try await run(Self.arguments("fix-thread", thread)))
    }

    public func reply(_ thread: ThreadRef, body: String) async throws {
        _ = try await run(Self.arguments("reply-thread", thread, extra: ["--body", body]))
    }

    static func parseExplanation(_ out: String) throws -> ThreadExplanation {
        struct Payload: Decodable {
            let reasoning: String
            let proposedFix: String
            enum CodingKeys: String, CodingKey { case reasoning, proposedFix = "proposed_fix" }
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: Data(out.utf8)),
            !p.reasoning.isEmpty, !p.proposedFix.isEmpty
        else { throw ThreadWorkbenchError.unreadable(out) }
        return ThreadExplanation(reasoning: p.reasoning, proposedFix: p.proposedFix)
    }

    static func parseCommit(_ out: String) throws -> String {
        struct Payload: Decodable { let commit: String }
        guard let p = try? JSONDecoder().decode(Payload.self, from: Data(out.utf8)),
            (7...40).contains(p.commit.count), p.commit.allSatisfy(\.isHexDigit)
        else { throw ThreadWorkbenchError.unreadable(out) }
        return p.commit.lowercased()
    }
}

/// What the buttons do. Each one is a single, explicit step: Fix never resolves, and neither does dismissing.
public struct ThreadActions: Sendable {
    public var workbench: any ThreadWorkbench
    public var forge: any ForgeClient

    public init(workbench: any ThreadWorkbench, forge: any ForgeClient) {
        self.workbench = workbench
        self.forge = forge
    }

    public struct FixOutcome: Equatable, Sendable {
        public var commit: String
        public var reply: String
    }

    /// "Fixed in <short sha>": a reply PR 2's thread states read back as a reported fix.
    public static func replyText(commit: String) -> String { "Fixed in \(ThreadState.shortSha(commit))" }

    public func explain(_ thread: ThreadRef) async throws -> ThreadExplanation {
        try await workbench.explain(thread)
    }

    /// Pushes the fix, then posts the reply. `willReply` gets the reply's text just before it is posted, so it can be
    /// shown. If the reply fails after the push, the error says which commit went out.
    public func fix(_ thread: ThreadRef, willReply: @Sendable (String) -> Void = { _ in }) async throws -> FixOutcome {
        let commit = try await workbench.fix(thread)
        let text = Self.replyText(commit: commit)
        willReply(text)
        do {
            try await workbench.reply(thread, body: text)
        } catch {
            throw ThreadWorkbenchError.failed(
                "Pushed \(ThreadState.shortSha(commit)) but couldn't reply: \(error.localizedDescription)")
        }
        return FixOutcome(commit: commit, reply: text)
    }

    /// The only call that resolves a thread.
    public func resolve(_ pr: PullRequest, threadID: String) async throws {
        try await forge.resolveThread(pr, threadID: threadID)
    }
}
