import Foundation
import Testing

@testable import TriageCore

private let host = "gitlab.com"

/// A trimmed real-shaped detail response, decoded exactly as GitLabClient does.
private func detail(
    status: String = "MERGEABLE", reviewState: String = "UNREVIEWED", approved: Bool = false, approvalsLeft: Int = 1,
    approvers: String = "", extraNote: String = ""
) -> String {
    """
    {"data": {"project": {"mergeRequest": {
      "iid": "12", "title": "Add billing export", "description": "Exports invoices as CSV.",
      "webUrl": "https://gitlab.com/acme/platform/web/-/merge_requests/12", "draft": false,
      "createdAt": "2026-09-20T10:00:00Z", "updatedAt": "2026-09-27T10:00:00.123Z",
      "sourceBranch": "feat/export", "diffHeadSha": "abc123",
      "detailedMergeStatus": "\(status)", "conflicts": false,
      "approved": \(approved), "approvalsLeft": \(approvalsLeft),
      "author": {"username": "gabriel", "avatarUrl": "/uploads/-/system/user/avatar/1/a.png", "bot": false},
      "approvedBy": {"nodes": [\(approvers)]},
      "reviewers": {"nodes": [{"username": "rita", "mergeRequestInteraction": {"reviewState": "\(reviewState)"}}]},
      "headPipeline": {"jobs": {"count": 3, "nodes": [
        {"id": "gid://gitlab/Ci::Build/901", "name": "test", "status": "FAILED", "allowFailure": false,
         "webPath": "/acme/platform/web/-/jobs/901"},
        {"id": "gid://gitlab/Ci::Build/902", "name": "lint", "status": "FAILED", "allowFailure": true,
         "webPath": "/acme/platform/web/-/jobs/902"},
        {"id": "gid://gitlab/Ci::Build/903", "name": "deploy", "status": "RUNNING", "allowFailure": false,
         "webPath": null}
      ]}},
      "discussions": {"pageInfo": {"hasNextPage": false}, "nodes": [
        {"resolvable": true, "resolved": false, "notes": {"nodes": [
          {"id": "gid://gitlab/Note/101",
           "body": "Can this be null?", "system": false, "url": "https://gitlab.com/acme/platform/web/-/merge_requests/12#note_1",
           "createdAt": "2026-09-21T10:00:00Z", "author": {"username": "rita", "bot": false},
           "position": {"newPath": "Sources/Export.swift", "newLine": 42}},
          {"id": "gid://gitlab/Note/102",
           "body": "Good point", "system": false, "url": null, "createdAt": "2026-09-21T11:00:00Z",
           "author": {"username": "gabriel", "bot": false}, "position": null}
        ]}},
        {"resolvable": true, "resolved": true, "notes": {"nodes": [
          {"id": "gid://gitlab/Note/103",
           "body": "Typo", "system": false, "url": null, "createdAt": "2026-09-21T10:00:00Z",
           "author": {"username": "rita", "bot": false}, "position": null}
        ]}},
        {"resolvable": false, "resolved": false, "notes": {"nodes": [
          {"id": "gid://gitlab/Note/104",
           "body": "added 3 commits", "system": true, "url": null, "createdAt": "2026-09-22T10:00:00Z",
           "author": {"username": "gabriel", "bot": false}, "position": null}
        ]}},
        {"resolvable": false, "resolved": false, "notes": {"nodes": [
          {"id": "gid://gitlab/Note/105",
           "body": "Coverage dropped 2%", "system": false, "url": null, "createdAt": "2026-09-22T10:00:00Z",
           "author": {"username": "project_77_bot_3f2a", "bot": false}, "position": null}
        ]}}\(extraNote)
      ]}
    }}}}
    """
}

private func model(_ json: String) throws -> (PullRequest, [String]) {
    let d: DetailData = try GitLabClient.decode(Data(json.utf8))
    let mr = try #require(d.project?.mergeRequest)
    let repo = try #require(RepoRef(gitlabPath: "acme/platform/web", host: host))
    return (mr.toModel(repo: repo), mr.truncationWarnings(repo: repo))
}

@Test func mapsAMergeRequestOntoAPullRequest() throws {
    let (pr, warnings) = try model(detail())
    #expect(pr.id == "gitlab.com/acme/platform/web#12")
    #expect(pr.number == 12)
    #expect(pr.author == "gabriel")
    #expect(pr.authorAvatar?.absoluteString == "https://gitlab.com/uploads/-/system/user/avatar/1/a.png")
    #expect(pr.headSha == "abc123")
    #expect(pr.headRef == "feat/export")
    #expect(pr.summary == "Exports invoices as CSV.")
    #expect(pr.mergeable == .mergeable)
    #expect(pr.reviewDecision == .reviewRequired)
    #expect(pr.updatedAt.timeIntervalSince1970 > pr.createdAt.timeIntervalSince1970)  // fractional seconds decode
    #expect(pr.checks.map(\.state) == [.failure, .neutral, .pending])
    #expect(pr.checks[0].checkRunID == 901)
    #expect(pr.checks[0].url?.absoluteString == "https://gitlab.com/acme/platform/web/-/jobs/901")
    #expect(pr.checks[2].url == nil)
    #expect(warnings.isEmpty)
}

@Test func cappedJobsAndDiscussionsWarn() throws {
    let capped = detail()
        .replacingOccurrences(of: #""count": 3"#, with: #""count": 130"#)
        .replacingOccurrences(of: #""hasNextPage": false"#, with: #""hasNextPage": true"#)
    #expect(
        try model(capped).1 == [
            "acme/platform/web!12: read the first 3 of 130 jobs",
            "acme/platform/web!12: read the first 4 discussions",
        ])
}

@Test func discussionsSplitIntoThreadsAndComments() throws {
    let (pr, _) = try model(detail())
    #expect(pr.threads.count == 2)
    let open = try #require(pr.threads.first { !$0.isResolved })
    #expect(open.path == "Sources/Export.swift")
    #expect(open.line == 42)
    #expect(open.isOutdated == false)
    #expect(open.comments.map(\.author) == ["rita", "gabriel"])
    #expect(open.firstComment.url?.absoluteString.hasSuffix("#note_1") == true)
    // No `url` from GitLab: the anchor built from the note id stands in, so item ids still move on a reply.
    #expect(
        open.comments[1].url?.absoluteString
            == "https://gitlab.com/acme/platform/web/-/merge_requests/12#note_102")
    // The system note is dropped; the access-token bot's comment stays, flagged as a bot.
    #expect(pr.comments.map(\.body) == ["Coverage dropped 2%"])
    #expect(pr.comments[0].isBot)
}

/// Pushes add system notes ("added 3 commits"); they mustn't change item ids, or dismissals would reset.
@Test func systemNotesDontChangeItemIds() throws {
    let more = """
        ,
        {"resolvable": false, "resolved": false, "notes": {"nodes": [
          {"id": "gid://gitlab/Note/106", "body": "changed the description", "system": true, "url": null,
           "createdAt": "2026-09-27T10:00:00Z",
           "author": {"username": "rita", "bot": false}, "position": null}
        ]}}
        """
    let before = Classifier.classify(try model(detail()).0, viewer: "gabriel").items.map(\.id)
    let after = Classifier.classify(try model(detail(extraNote: more)).0, viewer: "gabriel").items.map(\.id)
    #expect(!before.isEmpty)
    #expect(before == after)
}

@Test func classifiesLikeAGitHubPR() throws {
    let kinds = Classifier.classify(try model(detail()).0, viewer: "gabriel").items.map(\.kind)
    #expect(kinds.contains(.ciFailure))
    #expect(kinds.contains(.reviewThreads))
    #expect(!kinds.contains(.readyToMerge))
}

@Test func reviewStateMapsOntoReviewDecision() throws {
    #expect(try model(detail(reviewState: "REQUESTED_CHANGES")).0.reviewDecision == .changesRequested)
    let rita = #"{"username": "rita"}"#
    let approved = try model(detail(approved: true, approvalsLeft: 0, approvers: rita)).0
    #expect(approved.reviewDecision == .approved)
    #expect(approved.approvedBy == ["rita"])
    // No approval rules: GitLab says "approved" with nobody approving. That isn't ready to merge.
    #expect(try model(detail(approved: true, approvalsLeft: 0)).0.reviewDecision == ReviewDecision.none)
}

@Test func mergeStatusMapsOntoMergeable() throws {
    #expect(try model(detail(status: "CONFLICT")).0.mergeable == .conflicting)
    #expect(try model(detail(status: "NEED_REBASE")).0.mergeable == .conflicting)
    #expect(try model(detail(status: "CHECKING")).0.mergeable == .unknown)
    #expect(try model(detail(status: "NOT_APPROVED")).0.mergeable == .mergeable)
}

@Test func botsIncludeAccessTokenUsers() {
    #expect(GLUser(username: "project_77_bot_3f2a", avatarUrl: nil, bot: nil).isBot)
    #expect(GLUser(username: "group_5_bot", avatarUrl: nil, bot: false).isBot)
    #expect(GLUser(username: "renovate", avatarUrl: nil, bot: true).isBot)
    #expect(!GLUser(username: "project_manager", avatarUrl: nil, bot: false).isBot)
}

@Test func listDedupesAndWarnsWhenCapped() throws {
    let json = """
        {"data": {"currentUser": {
          "assignedMergeRequests": {"pageInfo": {"hasNextPage": true}, "nodes": [
            {"iid": "12", "project": {"fullPath": "acme/web"}}, {"iid": "3", "project": {"fullPath": "acme/api"}}]},
          "reviewRequestedMergeRequests": {"pageInfo": {"hasNextPage": false}, "nodes": [
            {"iid": "12", "project": {"fullPath": "acme/web"}}, {"iid": "12", "project": {"fullPath": "acme/api"}}]}
        }}}
        """
    let list: ListData = try GitLabClient.decode(Data(json.utf8))
    let (refs, warnings) = list.refs()
    #expect(refs.map { "\($0.projectPath)!\($0.iid)" } == ["acme/web!12", "acme/api!3", "acme/api!12"])
    #expect(warnings == ["GitLab: showing the 2 most recently updated merge requests assigned to you"])
}

@Test func graphqlErrorsSurface() {
    let json =
        #"{"data": null, "errors": [{"message": "Query has complexity of 300, which exceeds max complexity of 250"}]}"#
    #expect(throws: GitLabError.self) { let _: ListData = try GitLabClient.decode(Data(json.utf8)) }
    #expect(GitLabError.http(401, "").localizedDescription.contains("token"))
    #expect(GitLabError.http(404, #"{"message": "404 Project Not Found"}"#).localizedDescription.contains("Not Found"))
}

@Test func oneFailedMergeRequestIsAWarningNotALostRefresh() throws {
    let (pr, _) = try model(detail())
    let ok = GitLabClient.Detail(pr: pr, warnings: ["capped"])
    let failed = RepoError(repo: "acme/api!3", underlying: Boom())
    let snap = try GitLabClient.snapshot([.success(ok), .failure(failed)], warnings: ["list"])
    #expect(snap.pullRequests.map(\.id) == [pr.id])
    #expect(snap.warnings == ["list", "acme/api!3: boom", "capped"])
    #expect(throws: RepoError.self) { try GitLabClient.snapshot([.failure(failed)], warnings: []) }
    #expect(try GitLabClient.snapshot([], warnings: []).pullRequests.isEmpty)
}
