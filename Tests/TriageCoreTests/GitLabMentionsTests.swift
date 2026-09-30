import Foundation
import Testing

@testable import TriageCore

private let json = """
    {"data": {"currentUser": {"todos": {"nodes": [
      {"id": "gid://gitlab/Todo/3", "createdAt": "2026-09-29T19:43:05Z", "body": "fallback",
       "targetUrl": "https://gitlab.com/acme/platform/web/-/merge_requests/70526",
       "author": {"username": "mateus", "name": "Mateus", "bot": false},
       "note": {"url": "https://gitlab.com/acme/platform/web/-/merge_requests/70526#note_9",
         "body": "@me heads up,\\nnot a review",
         "discussion": {"notes": {"nodes": [
           {"createdAt": "2026-09-29T19:43:05Z", "author": {"username": "mateus"}},
           {"createdAt": "2026-09-29T20:00:00Z", "author": {"username": "me"}},
           {"createdAt": "2026-09-29T21:00:00Z", "author": null}]}}},
       "target": {"__typename": "MergeRequest", "state": "opened", "reference": "acme/platform/web!70526",
         "title": "Fix copy"}},
      {"id": "gid://gitlab/Todo/2", "createdAt": "2026-09-07T09:17:55Z", "body": "review",
       "targetUrl": "https://gitlab.com/acme/platform/web/-/merge_requests/92530",
       "author": {"username": "project_77_bot_3f2a", "name": "cursor", "bot": false},
       "note": {"url": "https://gitlab.com/acme/platform/web/-/merge_requests/92530#note_1", "body": "finding"},
       "target": {"__typename": "MergeRequest", "state": "merged", "reference": "acme/platform/web!92530",
         "title": "Other"}},
      {"id": "gid://gitlab/Todo/1", "createdAt": "2026-09-01T10:00:00Z", "body": "on an issue",
       "targetUrl": "https://gitlab.com/acme/platform/web/-/issues/4",
       "author": {"username": "rita", "name": "Rita", "bot": false}, "note": null,
       "target": {"__typename": "Issue", "reference": "acme/platform/web#4", "title": "Bug"}},
      {"id": "gid://gitlab/Todo/0", "createdAt": "2026-09-01T09:00:00Z", "body": "x",
       "targetUrl": "javascript:alert(1)", "author": {"username": "eve", "name": "Eve", "bot": false},
       "note": null, "target": null}
    ]}}}}
    """

private func decoded() throws -> [GitLabMention] {
    let d: MentionsData = try GitLabClient.decode(Data(json.utf8))
    return d.mentions()
}

@Test func mentionsDecodeWithTheCommentLinkAndAShortReference() throws {
    let m = try decoded()
    #expect(
        m.map(\.id) == [
            "gitlab-mention:gid://gitlab/Todo/3", "gitlab-mention:gid://gitlab/Todo/2",
            "gitlab-mention:gid://gitlab/Todo/1",
        ])
    #expect(m.allSatisfy { GitLabMention.isMentionID($0.id) })
    #expect(m[0].author == "mateus")
    #expect(m[0].target == "web !70526")
    #expect(m[0].url.absoluteString.hasSuffix("#note_9"))
    #expect(m[0].excerpt == "@me heads up, not a review")
    #expect(m[0].body == "@me heads up,\nnot a review")
    // A note from a deleted user has no author, so it's left out.
    #expect(m[0].thread.map(\.author) == ["mateus", "me"])
    #expect(m[0].targetOpen && !m[1].targetOpen)
    // An access-token user is a bot, named by its display name.
    #expect(m[1].isBot && m[1].author == "cursor")
    // No note: the issue itself, and the to-do's body.
    #expect(m[2].target == "web #4" && m[2].url.absoluteString.hasSuffix("/issues/4") && m[2].excerpt == "on an issue")
    // No state asked for: counted as open rather than hidden.
    #expect(m[2].targetOpen && m[2].thread.isEmpty)
}

@Test func aMentionWithoutAWebLinkIsDropped() throws {
    #expect(try !decoded().contains { $0.author == "eve" })
}

private func mention(_ n: Int, by author: String = "rita", bot: Bool = false) -> GitLabMention {
    GitLabMention(
        id: "t\(n)", author: author, isBot: bot, target: "web !\(n)", targetTitle: "Title \(n)",
        url: URL(string: "https://gitlab.com/x/-/merge_requests/\(n)#note_1")!, excerpt: "hey @me",
        createdAt: Date(timeIntervalSince1970: TimeInterval(n)))
}

@Test func theFirstPollOnlyRecordsWhatsThere() {
    let (alerts, state) = MentionAlerts.plan([mention(1), mention(2)], viewer: "me", state: MentionAlertState())
    #expect(alerts.isEmpty)
    #expect(state.started && state.seen == ["t1", "t2"])
}

@Test func aNewMentionNotifiesOnce() {
    let (_, s1) = MentionAlerts.plan([mention(1)], viewer: "me", state: MentionAlertState())
    let (alerts, s2) = MentionAlerts.plan([mention(2), mention(1)], viewer: "me", state: s1)
    #expect(alerts == [.new(mention(2))])
    #expect(alerts[0].title == "rita mentioned you")
    #expect(alerts[0].subtitle == "web !2 · Title 2")
    #expect(alerts[0].url.absoluteString.hasSuffix("/2#note_1"))
    #expect(MentionAlerts.plan([mention(2), mention(1)], viewer: "me", state: s2).alerts.isEmpty)
}

@Test func botsAndYourselfDontNotify() {
    let (_, s1) = MentionAlerts.plan([], viewer: "me", state: MentionAlertState())
    let (alerts, s2) = MentionAlerts.plan([mention(1, bot: true), mention(2, by: "me")], viewer: "me", state: s1)
    #expect(alerts.isEmpty)
    #expect(s2.seen == ["t1", "t2"])
}

@Test func mentionsThatFellOffThePageAreForgotten() {
    let (_, s1) = MentionAlerts.plan([mention(1)], viewer: "me", state: MentionAlertState())
    #expect(MentionAlerts.plan([mention(2)], viewer: "me", state: s1).state.seen == ["t2"])
}

@Test func manyAtOnceAreOneSummaryThatOpensTheNewest() {
    let (_, s1) = MentionAlerts.plan([], viewer: "me", state: MentionAlertState())
    let (alerts, _) = MentionAlerts.plan((1...4).map { mention($0) }, viewer: "me", state: s1)
    #expect(alerts == [.summary(count: 4, newest: mention(4))])
    #expect(alerts[0].title == "4 new GitLab mentions")
    #expect(alerts[0].url == mention(4).url)
}

@Test func shortReferencesKeepTheProjectName() {
    #expect(MentionsData.shortReference("group/sub/tiger!96285") == "tiger !96285")
    #expect(MentionsData.shortReference("tiger#4") == "tiger #4")
    #expect(MentionsData.shortReference("!7") == "!7")
}

private let now = Date(timeIntervalSince1970: 100 * 24 * 3600)

private func at(_ daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 24 * 3600) }

private func pinged(
    _ id: String, by author: String = "rita", daysAgo: Double = 1, open: Bool = true, bot: Bool = false,
    thread: [GitLabMention.Reply] = []
) -> GitLabMention {
    GitLabMention(
        id: "gitlab-mention:\(id)", author: author, isBot: bot, target: "web !1", targetTitle: "T", targetOpen: open,
        url: URL(string: "https://gitlab.com/x")!, excerpt: "hey", createdAt: at(daysAgo), thread: thread)
}

@Test func onlyMentionsWaitingOnMeAreListedNewestFirst() {
    let mentions = [
        pinged("old", daysAgo: 3), pinged("new", daysAgo: 1),
        pinged("bot", bot: true), pinged("self", by: "me"), pinged("merged", open: false),
        pinged("stale", daysAgo: 31),
        pinged("answered", daysAgo: 2, thread: [.init(author: "me", createdAt: at(1))]),
    ]
    #expect(
        GitLabMentions.waiting(mentions, viewer: "me", now: now).map(\.id) == [
            "gitlab-mention:new", "gitlab-mention:old",
        ])
}

@Test func aReplyBeforeTheMentionDoesntAnswerIt() {
    // You wrote in the thread earlier, then someone mentioned you: still waiting.
    let m = pinged(
        "m", daysAgo: 1, thread: [.init(author: "me", createdAt: at(2)), .init(author: "bob", createdAt: at(0.5))])
    #expect(GitLabMentions.waiting([m], viewer: "me", now: now).count == 1)
}
