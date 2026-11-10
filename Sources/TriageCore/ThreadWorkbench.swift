import Foundation

/// Explain a review thread through Workbench. Triage asks `workbench explain-thread` and shows the reasoning and the
/// proposed fix. Nothing is changed, pushed or posted on the forge.

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
    /// The commit Workbench says it analysed, when it says. The PR may have moved since Triage last refreshed, and
    /// the explanation belongs to the head it was written for.
    public var head: String?

    public init(reasoning: String, proposedFix: String, head: String? = nil) {
        self.reasoning = reasoning
        self.proposedFix = proposedFix
        self.head = head
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

/// What Triage keeps about threads on this Mac: explanations by thread id, each knowing its head SHA. They are never
/// sent to the forge.
public struct ThreadTriage: Codable, Equatable, Sendable {
    public private(set) var explanations: [String: ThreadExplanationRecord] = [:]

    public init() {}

    public mutating func store(_ explanation: ThreadExplanation, for thread: ThreadRef, at: Date = Date()) {
        explanations[thread.threadID] = ThreadExplanationRecord(
            head: explanation.head ?? thread.head, explanation: explanation, at: at)
    }

    /// The explanation for a thread, stale once the PR's head is not the one it was written for.
    public func status(of threadID: String, head: String, running: Bool = false) -> ThreadExplanationStatus {
        if running { return .running }
        guard let record = explanations[threadID] else { return .none }
        let moved = ExplainPR.head7(record.head) != ExplainPR.head7(head)
        return moved ? .stale(record.explanation, at: record.at) : .current(record.explanation, at: record.at)
    }
}

/// What Workbench does for a thread. Behind a protocol so the app can run on a fake in mock mode.
public protocol ThreadWorkbench: Sendable {
    func explain(_ thread: ThreadRef) async throws -> ThreadExplanation
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

/// The real thing: `workbench explain-thread --pr <n> --thread <id>`, run in the local clone. It prints progress lines,
/// then as its last line one JSON object, `{"reasoning", "proposed_fix"}` and, when it knows, `"head_sha"`: the commit
/// it analysed (docs/plan/explain-thread.md in Workbench).
public struct CLIThreadWorkbench: ThreadWorkbench {
    public var workbench: String
    public var checkout: String
    public var personalRoot: String

    public init(workbench: String, checkout: String, personalRoot: String = "") {
        self.personalRoot = personalRoot
        self.workbench = workbench
        self.checkout = checkout
    }

    static func arguments(_ verb: String, _ thread: ThreadRef) -> [String] {
        [verb, "--pr", String(thread.number), "--thread", thread.threadID]
    }

    func run(_ arguments: [String]) async throws -> String {
        let result: Subprocess.Output
        do {
            result = try await Subprocess.run(
                workbench, arguments, directory: checkout,
                environment: ExplainPR.workbenchEnvironment(checkout: checkout, personalRoot: personalRoot))
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

    static func parseExplanation(_ out: String) throws -> ThreadExplanation {
        struct Payload: Decodable {
            let reasoning: String
            let proposedFix: String
            let head: String?
            enum CodingKeys: String, CodingKey { case reasoning, proposedFix = "proposed_fix", head = "head_sha" }
        }
        // The contract: the object is the last line, after any progress lines.
        let last = out.split(whereSeparator: \.isNewline).last.map(String.init) ?? out
        guard let p = try? JSONDecoder().decode(Payload.self, from: Data(last.utf8)),
            !p.reasoning.isEmpty, !p.proposedFix.isEmpty
        else { throw ThreadWorkbenchError.unreadable(out) }
        // `head` is optional; one that isn't a commit SHA is ignored rather than trusted.
        let head = p.head.flatMap { (7...40).contains($0.count) && $0.allSatisfy(\.isHexDigit) ? $0.lowercased() : nil }
        return ThreadExplanation(reasoning: p.reasoning, proposedFix: p.proposedFix, head: head)
    }
}

/// What the Explain button does.
public struct ThreadActions: Sendable {
    public var workbench: any ThreadWorkbench

    public init(workbench: any ThreadWorkbench) { self.workbench = workbench }

    public func explain(_ thread: ThreadRef) async throws -> ThreadExplanation {
        try await workbench.explain(thread)
    }
}
