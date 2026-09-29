import Foundation
import Testing

@testable import TriageCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// ISO 8601 for `now` plus `hours`, as Linear sends it.
private func at(_ hours: Double) -> String {
    now.addingTimeInterval(hours * 3600).formatted(.iso8601)
}

private func mine(_ hours: [Double]) -> String {
    "{\"nodes\": [\(hours.map { "{\"createdAt\": \"\(at($0))\"}" }.joined(separator: ","))]}"
}

/// A made-up comment. `parent` is the JSON of its parent, or null for a top-level comment.
private func comment(
    id: String = "c1", body: String = "@me can you confirm the migration order?", resolved: Bool = false,
    myReplies: [Double] = [], parent: String = "null"
) -> String {
    """
    {"id": "\(id)", "body": \(String(reflecting: body)), "url": "https://linear.app/acme/issue/ENG-1#comment-\(id)",
     "createdAt": "\(at(-1))", "resolvedAt": \(resolved ? "\"\(at(-1))\"" : "null"),
     "children": \(mine(myReplies)), "parent": \(parent)}
    """
}

private func parent(byMe: Bool = false, resolved: Bool = false, myReplies: [Double] = []) -> String {
    """
    {"id": "root", "resolvedAt": \(resolved ? "\"\(at(-2))\"" : "null"), "user": {"isMe": \(byMe)},
     "children": \(mine(myReplies))}
    """
}

private func notification(
    id: String = "n1", category: String = "mentions", hours: Double = -1, snoozedFor: Double? = nil,
    actorIsMe: Bool = false, issue: String = "ENG-1", state: String = "started", myIssueComments: [Double] = [],
    comment: String? = comment()
) -> String {
    """
    {"__typename": "IssueNotification", "id": "\(id)", "type": "issueCommentMention", "category": "\(category)",
     "createdAt": "\(at(hours))", "snoozedUntilAt": \(snoozedFor.map { "\"\(at($0))\"" } ?? "null"),
     "actor": {"displayName": "Alice", "avatarUrl": null, "isMe": \(actorIsMe)},
     "issue": {"identifier": "\(issue)", "title": "Migrate billing", "url": "https://linear.app/acme/issue/\(issue)",
               "state": {"type": "\(state)"}, "comments": \(mine(myIssueComments))},
     "comment": \(comment ?? "null")}
    """
}

private func page(_ nodes: [String], next: String? = nil) throws -> NotificationsData {
    let json = """
        {"data": {"notifications": {
          "pageInfo": {"hasNextPage": \(next != nil), "endCursor": \(next.map { "\"\($0)\"" } ?? "null")},
          "nodes": [\(nodes.joined(separator: ","))]
        }}}
        """
    return try LinearClient.decode(Data(json.utf8))
}

private func pings(_ nodes: String...) throws -> [LinearPing] {
    LinearPings.classify(try page(nodes).notifications.nodes.compactMap(\.issueNotification), now: now)
}

@Suite struct LinearPingsTests {
    @Test func mentionInACommentIsOpenUntilIReplyInItsThread() throws {
        let open = try pings(notification())
        #expect(open.count == 1)
        #expect(open.first?.kind == .mentioned)
        #expect(open.first?.id == "linear:ENG-1:c1:c1")
        #expect(open.first?.excerpt == "@me can you confirm the migration order?")
        #expect(open.first?.url.absoluteString == "https://linear.app/acme/issue/ENG-1#comment-c1")
        #expect(open.first?.author == "Alice")

        #expect(try pings(notification(comment: comment(myReplies: [-0.5]))).isEmpty)
        // A reply of mine from before the ping doesn't answer it.
        #expect(try pings(notification(comment: comment(myReplies: [-3]))).count == 1)
    }

    @Test func replyCountsOnlyInAThreadIAmIn() throws {
        let inMyThread = notification(category: "commentsAndReplies", comment: comment(parent: parent(byMe: true)))
        #expect(try pings(inMyThread).first?.kind == .threadReply)

        let iRepliedBefore = notification(
            category: "commentsAndReplies", comment: comment(parent: parent(myReplies: [-5])))
        #expect(try pings(iRepliedBefore).first?.kind == .threadReply)

        let notMine = notification(category: "commentsAndReplies", comment: comment(parent: parent()))
        #expect(try pings(notMine).isEmpty)

        let topLevelOnFollowedIssue = notification(category: "commentsAndReplies")
        #expect(try pings(topLevelOnFollowedIssue).isEmpty)
    }

    @Test func myReplyAfterTheLatestPingAnswersTheThread() throws {
        let answered = notification(
            category: "commentsAndReplies", comment: comment(parent: parent(byMe: true, myReplies: [-0.5])))
        #expect(try pings(answered).isEmpty)
    }

    @Test func twoRepliesInOneThreadAreOneItemShowingTheLater() throws {
        let first = notification(
            id: "n1", category: "commentsAndReplies", hours: -3,
            comment: comment(id: "c1", body: "first", parent: parent(byMe: true)))
        let second = notification(
            id: "n2", category: "commentsAndReplies", hours: -1,
            comment: comment(id: "c2", body: "second", parent: parent(byMe: true)))

        let one = try pings(first)
        let both = try pings(first, second)
        #expect(both.count == 1)
        #expect(both.first?.excerpt == "second")
        #expect(both.first?.threadID == "ENG-1:root")
        // A new reply changes the id, so a dismissed thread comes back.
        #expect(one.first?.id == "linear:ENG-1:root:c1")
        #expect(both.first?.id == "linear:ENG-1:root:c2")
    }

    @Test func myReplyBetweenTwoPingsLeavesTheThreadOpen() throws {
        let replies = parent(byMe: true, myReplies: [-2])
        let before = notification(
            id: "n1", category: "commentsAndReplies", hours: -3, comment: comment(id: "c1", parent: replies))
        let after = notification(
            id: "n2", category: "commentsAndReplies", hours: -1, comment: comment(id: "c2", parent: replies))
        #expect(try pings(before, after).map(\.id) == ["linear:ENG-1:root:c2"])
    }

    @Test(arguments: ["completed", "canceled", "duplicate"])
    func closedIssueClearsIt(state: String) throws {
        #expect(try pings(notification(state: state)).isEmpty)
    }

    @Test func resolvedThreadClearsIt() throws {
        #expect(try pings(notification(comment: comment(resolved: true))).isEmpty)
        let resolvedRoot = notification(
            category: "commentsAndReplies", comment: comment(parent: parent(byMe: true, resolved: true)))
        #expect(try pings(resolvedRoot).isEmpty)
    }

    @Test func snoozedInLinearHidesItUntilTheSnoozeEnds() throws {
        #expect(try pings(notification(snoozedFor: 2)).isEmpty)
        #expect(try pings(notification(snoozedFor: -1)).count == 1)
    }

    @Test func myOwnActionsAreNotPings() throws {
        #expect(try pings(notification(actorIsMe: true)).isEmpty)
    }

    @Test func pingsOlderThan30DaysAreDropped() throws {
        #expect(try pings(notification(hours: -31 * 24)).isEmpty)
        #expect(try pings(notification(hours: -29 * 24)).count == 1)
    }

    @Test func descriptionMentionIsAnsweredByAnyCommentOfMineOnTheIssue() throws {
        let open = try pings(notification(comment: nil))
        #expect(open.first?.id == "linear:ENG-1:issue:n1")
        #expect(open.first?.excerpt == "Migrate billing")
        #expect(open.first?.url.absoluteString == "https://linear.app/acme/issue/ENG-1")

        #expect(try pings(notification(myIssueComments: [-0.5], comment: nil)).isEmpty)
        #expect(try pings(notification(myIssueComments: [-2], comment: nil)).count == 1)
    }

    @Test func otherCategoriesAreIgnored() throws {
        for category in ["assignments", "statusChanges", "reactions", "subscriptions"] {
            #expect(try pings(notification(category: category)).isEmpty)
        }
    }

    @Test func newestPingFirst() throws {
        let older = notification(id: "n1", hours: -5, issue: "ENG-1", comment: comment(id: "a"))
        let newer = notification(id: "n2", hours: -1, issue: "ENG-2", comment: comment(id: "b"))
        #expect(try pings(older, newer).map(\.issueKey) == ["ENG-2", "ENG-1"])
    }

    @Test func excerptIsTheFirstNonEmptyLineCapped() {
        #expect(LinearPings.excerpt("\n  \n  Hey @me  \nmore") == "Hey @me")
        let long = LinearPings.excerpt(String(repeating: "a", count: 200))
        #expect(long.count == 140)
        #expect(long.hasSuffix("…"))
    }
}

@Suite struct LinearDecodingTests {
    @Test func nonIssueNotificationsDecodeToNil() throws {
        let project = #"{"__typename": "ProjectNotification", "id": "p1"}"#
        let decoded = try page([project, notification()], next: "cursor-2")
        #expect(decoded.notifications.nodes.compactMap(\.issueNotification).count == 1)
        #expect(decoded.notifications.pageInfo.hasNextPage)
        #expect(decoded.notifications.pageInfo.endCursor == "cursor-2")
    }

    @Test func graphqlErrorsSurface() {
        let json = #"{"data": null, "errors": [{"message": "Authentication required"}]}"#
        #expect(throws: LinearError.self) {
            let _: NotificationsData = try LinearClient.decode(Data(json.utf8))
        }
    }

    @Test func unauthorizedSaysToMakeANewKey() {
        #expect(LinearError.http(401, "").localizedDescription.contains("Read access"))
    }
}
