import Foundation
import Testing

@testable import TriageCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let scenarioJSON = """
    {"github":{"viewer":"gabi","repos":["acme/api"]},"pullRequests":[
      {"repo":"acme/api","number":81,"title":"Retry budget","author":"gabi","createdHoursAgo":10,
       "headSha":"1111111111111111111111111111111111111111",
       "commits":["1111111111111111111111111111111111111111"],
       "threads":[
         {"id":"t1","author":"cursor[bot]","isBot":true,"path":"a.go","line":1,"body":"Possible nil dereference."},
         {"id":"t2","author":"cursor[bot]","isBot":true,"path":"b.go","line":2,"body":"Unbounded backoff."}]}]}
    """

private func makeWorld() throws -> MockWorld {
    try MockWorld(try JSONDecoder().decode(MockScenario.self, from: Data(scenarioJSON.utf8)), now: now)
}

private func fetchPR(_ world: MockWorld) async throws -> PullRequest {
    let forge = try world.forgeClient(.github, repos: world.repos)
    let results = try await forge.fetch()
    let snapshot = try #require(results.first).result.get()
    return try #require(snapshot.pullRequests.first)
}

private func ref(_ pr: PullRequest, _ id: String) -> ThreadRef {
    ThreadRef(repo: pr.repo, number: pr.number, threadID: id, head: pr.headSha)
}

/// A Workbench that records every call, in order, and answers with fixed text.
private final class RecordingWorkbench: ThreadWorkbench, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }
    var failReply = false

    private func record(_ call: String) { lock.withLock { log.append(call) } }

    func explain(_ thread: ThreadRef) async throws -> ThreadExplanation {
        record("explain \(thread.threadID)")
        return ThreadExplanation(reasoning: "Because.", proposedFix: "Guard it.")
    }

    func fix(_ thread: ThreadRef) async throws -> String {
        record("fix \(thread.threadID)")
        return "9f3c2e1a7b4d5e6f8091a2b3c4d5e6f708192a3b"
    }

    func reply(_ thread: ThreadRef, body: String) async throws {
        record("reply \(thread.threadID): \(body)")
        if failReply { throw ThreadWorkbenchError.failed("offline") }
    }
}

@Suite struct ThreadWorkbenchTests {
    @Test func explainFixAndReply() async throws {
        let world = try makeWorld()
        let pr = try await fetchPR(world)
        let workbench = world.threadWorkbench()
        let thread = ref(pr, "t1")

        let explanation = try await workbench.explain(thread)
        #expect(!explanation.reasoning.isEmpty)
        #expect(!explanation.proposedFix.isEmpty)

        let commit = try await workbench.fix(thread)
        #expect(commit.count == 40)
        try await workbench.reply(thread, body: "Fixed in \(commit.prefix(7))")

        let after = try await fetchPR(world)
        #expect(after.commitShas.contains(commit))
        let replies = try #require(after.threads.first { $0.id == "t1" }).comments.dropFirst().map(\.body)
        #expect(replies == ["Fixed in \(commit.prefix(7))"])
    }

    @Test func commandLineArguments() {
        let thread = ThreadRef(
            repo: RepoRef(owner: "acme", name: "api"), number: 81, threadID: "PRRT_x", head: "abc")
        #expect(
            CLIThreadWorkbench.arguments("explain-thread", thread)
                == ["explain-thread", "--pr", "81", "--thread", "PRRT_x"])
        #expect(
            CLIThreadWorkbench.arguments("reply-thread", thread, extra: ["--body", "Fixed in abc1234"])
                == ["reply-thread", "--pr", "81", "--thread", "PRRT_x", "--body", "Fixed in abc1234"])
    }

    @Test func parsesWorkbenchAnswers() throws {
        let e = try CLIThreadWorkbench.parseExplanation(#"{"reasoning":"R","proposed_fix":"F"}"#)
        #expect(e == ThreadExplanation(reasoning: "R", proposedFix: "F"))
        #expect(throws: ThreadWorkbenchError.self) { try CLIThreadWorkbench.parseExplanation("nope") }
        #expect(throws: ThreadWorkbenchError.self) {
            try CLIThreadWorkbench.parseExplanation(#"{"reasoning":"","proposed_fix":"F"}"#)
        }
        #expect(try CLIThreadWorkbench.parseCommit(#"{"commit":"9F3C2E1"}"#) == "9f3c2e1")
        #expect(throws: ThreadWorkbenchError.self) { try CLIThreadWorkbench.parseCommit(#"{"commit":"zzz"}"#) }
        #expect(throws: ThreadWorkbenchError.self) { try CLIThreadWorkbench.parseCommit("pushed") }
        #expect(ThreadWorkbenchError.failed("x").errorDescription == "x")
        #expect(ThreadWorkbenchError.unreadable("y").errorDescription?.contains("y") == true)
    }
}

@Suite struct ThreadFixTests {
    @Test func userInitiatedFixReportsCommit() async throws {
        let world = try makeWorld()
        let pr = try await fetchPR(world)
        let workbench = RecordingWorkbench()
        let actions = ThreadActions(workbench: workbench, forge: try world.forgeClient(.github))
        let thread = ref(pr, "t1")

        // Explaining changes nothing: no fix, no reply.
        _ = try await actions.explain(thread)
        #expect(workbench.calls == ["explain t1"])

        let shown = ShownText()
        let out = try await actions.fix(thread) { shown.set($0) }
        #expect(out.commit == "9f3c2e1a7b4d5e6f8091a2b3c4d5e6f708192a3b")
        #expect(out.reply == "Fixed in 9f3c2e1")
        // The reply text was shown before it was posted, and the push came first.
        #expect(shown.value == "Fixed in 9f3c2e1")
        #expect(workbench.calls == ["explain t1", "fix t1", "reply t1: Fixed in 9f3c2e1"])
    }

    @Test func failedReplyNamesThePushedCommit() async throws {
        let world = try makeWorld()
        let pr = try await fetchPR(world)
        let workbench = RecordingWorkbench()
        workbench.failReply = true
        let actions = ThreadActions(workbench: workbench, forge: try world.forgeClient(.github))
        await #expect {
            try await actions.fix(ref(pr, "t1"))
        } throws: { error in
            (error as? ThreadWorkbenchError)?.errorDescription?.contains("Pushed 9f3c2e1") == true
        }
    }
}

private final class ShownText: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    var value: String? { lock.withLock { text } }
    func set(_ s: String) { lock.withLock { text = s } }
}

@Suite struct ThreadExplanationTests {
    @Test func explanationBecomesStaleWhenHeadChanges() {
        let repo = RepoRef(owner: "acme", name: "api")
        let old = "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let new = "2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        var triage = ThreadTriage()
        let e = ThreadExplanation(reasoning: "R", proposedFix: "F")
        #expect(triage.status(of: "t1", head: old) == .none)
        triage.store(e, for: ThreadRef(repo: repo, number: 1, threadID: "t1", head: old), at: now)
        #expect(triage.status(of: "t1", head: old) == .current(e, at: now))
        #expect(triage.status(of: "t1", head: new) == .stale(e, at: now))
        // Another thread has none, and a running one shows as running.
        #expect(triage.status(of: "t2", head: old) == .none)
        #expect(triage.status(of: "t1", head: old, running: true) == .running)
        #expect(ThreadExplanationStatus.running.explanation == nil)
        #expect(ThreadExplanationStatus.stale(e, at: now).explanation == e)
        // Explaining again at the new head makes it current.
        triage.store(e, for: ThreadRef(repo: repo, number: 1, threadID: "t1", head: new), at: now)
        #expect(triage.status(of: "t1", head: new) == .current(e, at: now))
    }

    @Test func triagePersists() throws {
        var triage = ThreadTriage()
        triage.dismissAsFalsePositive("t1")
        triage.store(
            ThreadExplanation(reasoning: "R", proposedFix: "F"),
            for: ThreadRef(repo: RepoRef(owner: "a", name: "b"), number: 1, threadID: "t1", head: "abc"), at: now)
        let back = try JSONDecoder().decode(ThreadTriage.self, from: JSONEncoder().encode(triage))
        #expect(back == triage)
    }
}
