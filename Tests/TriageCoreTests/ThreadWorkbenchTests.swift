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

@Suite struct ThreadWorkbenchTests {
    @Test func mockExplains() async throws {
        let world = try makeWorld()
        let pr = try await fetchPR(world)
        let explanation = try await world.threadWorkbench().explain(ref(pr, "t1"))
        #expect(!explanation.reasoning.isEmpty)
        #expect(!explanation.proposedFix.isEmpty)
        // Explaining changes nothing in the forge.
        #expect(try await fetchPR(world) == pr)
    }

    @Test func commandLineArguments() {
        let thread = ThreadRef(
            repo: RepoRef(owner: "acme", name: "api"), number: 81, threadID: "PRRT_x", head: "abc")
        #expect(
            CLIThreadWorkbench.arguments("explain-thread", thread)
                == ["explain-thread", "--pr", "81", "--thread", "PRRT_x"])
    }

    @Test func parsesWorkbenchAnswers() throws {
        let e = try CLIThreadWorkbench.parseExplanation(#"{"reasoning":"R","proposed_fix":"F"}"#)
        #expect(e == ThreadExplanation(reasoning: "R", proposedFix: "F"))
        #expect(throws: ThreadWorkbenchError.self) { try CLIThreadWorkbench.parseExplanation("nope") }
        #expect(throws: ThreadWorkbenchError.self) {
            try CLIThreadWorkbench.parseExplanation(#"{"reasoning":"","proposed_fix":"F"}"#)
        }
        #expect(ThreadWorkbenchError.failed("x").errorDescription == "x")
        #expect(ThreadWorkbenchError.unreadable("y").errorDescription?.contains("y") == true)
    }
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
        triage.store(
            ThreadExplanation(reasoning: "R", proposedFix: "F"),
            for: ThreadRef(repo: RepoRef(owner: "a", name: "b"), number: 1, threadID: "t1", head: "abc"), at: now)
        let back = try JSONDecoder().decode(ThreadTriage.self, from: JSONEncoder().encode(triage))
        #expect(back == triage)
    }
}
