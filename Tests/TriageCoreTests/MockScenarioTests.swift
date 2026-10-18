import Foundation
import Testing

@testable import TriageCore

/// The scenario `scripts/mock.sh` and `scripts/verify.sh` run on, read from the repo.
private let defaultScenarioURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Mocks/default.json")

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func scenario(_ json: String) throws -> MockScenario {
    try JSONDecoder().decode(MockScenario.self, from: Data(json.utf8))
}

private func world(prs: String, gitlab: String = "null") throws -> MockWorld {
    try MockWorld(
        scenario(
            """
            {"github":{"viewer":"me","repos":["acme/web"]},"gitlab":\(gitlab),"pullRequests":[\(prs)]}
            """), now: now)
}

private let pr = """
    {"repo":"acme/web","number":1,"title":"T","author":"me","createdHoursAgo":2}
    """

// MARK: - Loading

@Test func mockScenarioLoadsTheDefaultFile() throws {
    let scenario = try MockScenario.load(from: defaultScenarioURL)
    #expect(scenario.github.viewer == "gabi")
    #expect(scenario.pullRequests.count >= 10)
}

@Test func mockScenarioIsOffOnlyWhenTheVariableIsAbsent() throws {
    #expect(try MockScenario.fromEnvironment([:]) == nil)
}

@Test func mockScenarioWithAnEmptyVariableThrowsInsteadOfLaunchingTheRealApp() {
    #expect(throws: MockError.self) { try MockScenario.fromEnvironment([MockScenario.environmentKey: ""]) }
}

@Test func mockScenarioNamedByTheVariableLoads() throws {
    let loaded = try MockScenario.fromEnvironment([MockScenario.environmentKey: defaultScenarioURL.path])
    #expect(loaded?.name == "default")
}

@Test func mockScenarioWithAMissingFileThrowsInsteadOfFallingBack() {
    #expect(throws: MockError.self) {
        try MockScenario.fromEnvironment([MockScenario.environmentKey: "/no/such/scenario.json"])
    }
}

@Test func mockScenarioNamesTheFieldThatIsMissing() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(UUID().uuidString).json")
    try Data(#"{"github":{"viewer":"me"},"pullRequests":[]}"#.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    do {
        _ = try MockScenario.load(from: file)
        Issue.record("expected an invalid scenario")
    } catch let error as MockError {
        #expect(error.localizedDescription.contains("repos"))
    }
}

// MARK: - Pull requests

@Test func mockPullRequestTimesAreHoursBeforeNow() throws {
    let prs = try world(prs: pr).scenario.pullRequests
    let built = try MockWorld.pullRequest(prs[0], scenario: world(prs: pr).scenario, now: now)
    #expect(built.createdAt == now.addingTimeInterval(-2 * 3600))
    #expect(built.updatedAt == built.createdAt)
}

@Test func mockPullRequestWithNoHeadGetsTheSameOneEveryTime() {
    let first = MockWorld.stableSha("acme/web#1")
    #expect(first == MockWorld.stableSha("acme/web#1"))
    #expect(first != MockWorld.stableSha("acme/web#2"))
    #expect(first.count == 40)
}

@Test func mockPullRequestRejectsAnUnknownEnumValueAndListsTheChoices() {
    do {
        _ = try world(
            prs: #"{"repo":"acme/web","number":1,"title":"T","author":"me","createdHoursAgo":1,"mergeable":"MAYBE"}"#)
        Issue.record("expected an invalid scenario")
    } catch let error as MockError {
        #expect(error.localizedDescription.contains("MERGEABLE"))
    } catch { Issue.record("wrong error \(error)") }
}

@Test func mockPullRequestRejectsABadRepoAnUnknownForgeAndADuplicate() {
    #expect(throws: MockError.self) {
        try world(prs: #"{"repo":"web","number":1,"title":"T","author":"me","createdHoursAgo":1}"#)
    }
    #expect(throws: MockError.self) {
        try world(
            prs: #"{"repo":"acme/web","forge":"bitbucket","number":1,"title":"T","author":"me","createdHoursAgo":1}"#)
    }
    #expect(throws: MockError.self) { try world(prs: "\(pr),\(pr)") }
}

@Test func mockGitLabPullRequestNeedsAGitLabSectionAndAGroup() throws {
    let mr = #"{"repo":"platform/deploy","forge":"gitlab","number":5,"title":"T","author":"me","createdHoursAgo":1}"#
    #expect(throws: MockError.self) { try world(prs: mr) }
    let ok = try world(prs: mr, gitlab: #"{"host":"gitlab.test","viewer":"me"}"#)
    #expect(ok.gitlabHost == "gitlab.test")
    #expect(throws: MockError.self) {
        try world(
            prs: #"{"repo":"deploy","forge":"gitlab","number":5,"title":"T","author":"me","createdHoursAgo":1}"#,
            gitlab: #"{"host":"gitlab.test","viewer":"me"}"#)
    }
}

// MARK: - The fake forge

@Test func mockForgeFetchesOneResultPerWatchedRepo() async throws {
    let w = try world(prs: pr)
    let other = RepoRef(owner: "acme", name: "api")
    let client = try w.forgeClient(.github, repos: w.repos + [other])
    let results = try await client.fetch()
    #expect(results.map(\.repo.fullName) == ["acme/api", "acme/web"])
    #expect(try results.last?.result.get().pullRequests.map(\.number) == [1])
    #expect(try results.first?.result.get().pullRequests.isEmpty == true)
    #expect(try await client.viewer() == "me")
}

@Test func mockForgeRefusesAGitLabHostTheScenarioDoesNotHave() throws {
    let w = try world(prs: pr)
    #expect(throws: MockError.self) { try w.forgeClient(.gitlab(host: "gitlab.com")) }
}

@Test func mockForgeGroupsGitLabByProject() async throws {
    let mr = #"{"repo":"platform/deploy","forge":"gitlab","number":5,"title":"T","author":"me","createdHoursAgo":1}"#
    let w = try world(prs: "\(pr),\(mr)", gitlab: #"{"host":"gitlab.test","viewer":"gl"}"#)
    let client = try w.forgeClient(.gitlab(host: "gitlab.test"))
    let results = try await client.fetch()
    #expect(results.map(\.repo.fullName) == ["platform/deploy"])
    #expect(try await client.viewer() == "gl")
}

@Test func mockForgeApproveAddsTheViewerAndMergeAndCloseRemoveThePullRequest() async throws {
    let w = try world(
        prs: """
            {"repo":"acme/web","number":1,"title":"A","author":"x","createdHoursAgo":1,"requestedReviewers":["me"],
             "reviewDecision":"REVIEW_REQUIRED"},
            {"repo":"acme/web","number":2,"title":"B","author":"x","createdHoursAgo":1},
            {"repo":"acme/web","number":3,"title":"C","author":"x","createdHoursAgo":1}
            """)
    let client = try w.forgeClient(.github, repos: w.repos)
    func fetched() async throws -> [PullRequest] {
        try await client.fetch().flatMap { try $0.result.get().pullRequests }.sorted { $0.number < $1.number }
    }
    let first = try await fetched()
    try await client.approve(first[0])
    try await client.merge(first[1])
    try await client.close(first[2])
    let after = try await fetched()
    #expect(after.map(\.number) == [1])
    #expect(after[0].approvedBy == ["me"])
    #expect(after[0].requestedReviewers.isEmpty)
    #expect(after[0].reviewDecision == .approved)
}

@Test func mockForgeAnswersWithTheScenarioDiffAndLog() async throws {
    let w = try MockWorld(
        scenario(
            """
            {"github":{"viewer":"me","repos":["acme/web"]},"pullRequests":[\(pr)],"diff":"D","ciLog":"L"}
            """), now: now)
    let client = try w.forgeClient(.github, repos: w.repos)
    let first = try await client.fetch().flatMap { try $0.result.get().pullRequests }.first
    #expect(try await client.diff(#require(first)) == "D")
    #expect(try await client.ciLog(#require(first), checkRunID: 1) == "L")
}

// MARK: - Linear, mentions, Explain

@Test func mockLinearPingsClassifyAsMentionsAndReplies() async throws {
    let w = try MockWorld(
        scenario(
            """
            {"github":{"viewer":"me","repos":[]},"pullRequests":[],"linear":[
              {"kind":"mention","issue":"ENG-1","issueTitle":"A","actor":"Ann","hoursAgo":1,"body":"@me look"},
              {"kind":"reply","issue":"ENG-2","issueTitle":"B","actor":"Bo","hoursAgo":2,"body":"done"}]}
            """), now: now)
    #expect(w.hasLinear)
    let (notifications, warnings) = try await w.linear().notifications()
    #expect(warnings.isEmpty)
    let pings = LinearPings.classify(notifications, now: now)
    #expect(Set(pings.map(\.kind)) == [.mentioned, .threadReply])
    #expect(pings.first { $0.kind == .mentioned }?.headline == "Ann mentioned you")
}

@Test func mockLinearRejectsAnUnknownKind() {
    #expect(throws: MockError.self) {
        try MockWorld(
            scenario(
                """
                {"github":{"viewer":"me","repos":[]},"pullRequests":[],"linear":[
                  {"kind":"poke","issue":"ENG-1","issueTitle":"A","actor":"Ann","hoursAgo":1,"body":"x"}]}
                """), now: now)
    }
}

@Test func mockMentionsWaitUntilTheViewerReplies() async throws {
    let w = try MockWorld(
        scenario(
            """
            {"github":{"viewer":"me","repos":[]},"gitlab":{"host":"gitlab.test","viewer":"gl"},"pullRequests":[],
             "mentions":[
               {"id":"1","author":"li","target":"d !1","targetTitle":"T","hoursAgo":5,"body":"@gl ping"},
               {"id":"2","author":"li","target":"d !2","targetTitle":"T","hoursAgo":5,"body":"@gl again",
                "replies":[{"author":"gl","hoursAgo":1,"body":"ok"}]}]}
            """), now: now)
    let client = try w.forgeClient(.gitlab(host: "gitlab.test"))
    let source = try #require(client as? MentionsSource)
    let waiting = GitLabMentions.waiting(try await source.mentions(), viewer: "gl", now: now)
    #expect(waiting.map(\.id) == ["gitlab-mention:1"])
}

@Test func mockExplainerAnswersWithTheScenarioTextOrAFallback() async throws {
    let w = try world(prs: pr)
    #expect(try await w.explainer().complete(system: "s", prompt: "p") == MockExplainer.fallback)
    let custom = try MockWorld(
        scenario(#"{"github":{"viewer":"me","repos":[]},"pullRequests":[],"explanation":"E"}"#), now: now)
    #expect(try await custom.explainer().complete(system: "s", prompt: "p") == "E")
}

// MARK: - The default scenario cannot drift from the app

@Test func theDefaultScenarioClassifiesIntoEveryKindTheInboxHas() async throws {
    let w = try MockWorld(MockScenario.load(from: defaultScenarioURL), now: now)
    let github = try w.forgeClient(.github, repos: w.repos)
    let gitlab = try w.forgeClient(.gitlab(host: #require(w.gitlabHost)))
    var kinds: Set<AttentionKind> = []
    for (client, viewer) in [(github, w.githubViewer), (gitlab, try #require(w.gitlabViewer))] {
        for result in try await client.fetch() {
            for pr in try result.result.get().pullRequests {
                kinds.formUnion(Classifier.classify(pr, viewer: viewer, isNew: true).items.map(\.kind))
            }
        }
    }
    #expect(kinds == Set(AttentionKind.allCases))
}

@Test func theDefaultScenarioHasPingsAndAMentionAndCreationOrderThatDiffersFromNumbers() async throws {
    let w = try MockWorld(MockScenario.load(from: defaultScenarioURL), now: now)
    let pings = LinearPings.classify(try await w.linear().notifications().notifications, now: now)
    #expect(Set(pings.map(\.kind)) == [.mentioned, .threadReply])
    let gitlab = try w.forgeClient(.gitlab(host: #require(w.gitlabHost)))
    let mentions = try #require(gitlab as? MentionsSource)
    #expect(try await !mentions.mentions().isEmpty)

    let github = try w.forgeClient(.github, repos: w.repos)
    let prs = try await github.fetch().flatMap { try $0.result.get().pullRequests }
    let byNumber = prs.sorted { $0.number > $1.number }.map(\.number)
    let byCreation = prs.sorted { $0.createdAt > $1.createdAt }.map(\.number)
    #expect(byNumber != byCreation)
    #expect(prs.contains { $0.author == w.githubViewer } && prs.contains { $0.author != w.githubViewer })
}

@Test func theDefaultScenarioStartsTheNewPRClockSoOthersRecentPRsAreNew() async throws {
    let w = try MockWorld(MockScenario.load(from: defaultScenarioURL), now: now)
    var seen = SeenPRs()
    seen.startWatching(w.allRepos, now: w.watchingSince)
    let github = try w.forgeClient(.github, repos: w.repos)
    let prs = try await github.fetch().flatMap { try $0.result.get().pullRequests }
    let new = prs.filter { seen.isNew($0) }
    #expect(!new.isEmpty)
    #expect(new.allSatisfy { $0.createdAt > w.watchingSince })
    #expect(prs.contains { !seen.isNew($0) })
    let kinds = new.flatMap { Classifier.classify($0, viewer: w.githubViewer, isNew: true).items.map(\.kind) }
    #expect(kinds.contains(.newPR))
}

@Test func everythingOrderMockMatchesCreationHours() async throws {
    let w = try MockWorld(MockScenario.load(from: defaultScenarioURL), now: now)
    var seen = SeenPRs()
    seen.startWatching(w.allRepos, now: w.watchingSince)
    var items: [AttentionItem] = []
    for (client, viewer) in [
        (try w.forgeClient(.github, repos: w.repos), w.githubViewer),
        (try w.forgeClient(.gitlab(host: #require(w.gitlabHost))), try #require(w.gitlabViewer)),
    ] {
        for result in try await client.fetch() {
            for pr in try result.result.get().pullRequests {
                items += Classifier.classify(pr, viewer: viewer, isNew: seen.isNew(pr)).items
            }
        }
    }
    let inbox =
        items
        .sorted { ($0.severity, $0.pr.updatedAt) > ($1.severity, $1.pr.updatedAt) }
        .filter { !$0.kind.isPassive }
        .sortedByCreation()
    var shown: [(repo: String, number: Int)] = []
    for item in inbox {
        let key = (repo: item.pr.repo.fullName, number: item.pr.number)
        if let last = shown.last, last == key { continue }
        shown.append(key)
    }
    #expect(
        Set(shown.map { "\($0.repo)#\($0.number)" }).count == shown.count, "a pull request's items are not together")

    let expected = w.scenario.pullRequests
        .sorted { ($0.createdHoursAgo, -$0.number) < ($1.createdHoursAgo, -$1.number) }
        .map { "\($0.repo)#\($0.number)" }
        .filter { key in shown.contains { "\($0.repo)#\($0.number)" == key } }
    #expect(shown.map { "\($0.repo)#\($0.number)" } == expected)
    #expect(shown.count > 3)
}

@Test func mockWatchingDefaultsToADayAndFollowsTheScenario() throws {
    let w = try world(prs: pr)
    #expect(w.watchingSince == now.addingTimeInterval(-24 * 3600))
    let custom = try MockWorld(
        scenario(#"{"watchingHoursAgo":2,"github":{"viewer":"me","repos":[]},"pullRequests":[]}"#), now: now)
    #expect(custom.watchingSince == now.addingTimeInterval(-2 * 3600))
}
