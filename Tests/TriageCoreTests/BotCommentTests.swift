import Foundation
import Testing

@testable import TriageCore

private let ocrFinding = """
    <!-- devbox-ocr:finding -->
    **[test · medium]**

    Add a case for whitespace-only business details.
    """
private let ocrStatus = "<!-- devbox-ocr:status -->\n\n### Open Code Review complete\n\nRun `1` finished."
private let ocrSummary = "<!-- devbox-ocr:summary -->\n\n### Open Code Review\n\nReviewed `5e03fa55`: 1 minor."

private func thread(_ body: String, resolved: Bool, n: Int) -> ReviewThreadInfo {
    ReviewThreadInfo(
        isResolved: resolved, path: "a.exs", line: n,
        firstComment: CommentInfo(
            author: "Open Code Review", isBot: true, body: body, url: URL(string: "https://gl/x#note_\(n)")))
}

private func mr(threads: [ReviewThreadInfo], comments: [CommentInfo] = []) -> PullRequest {
    PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: 1, title: "t", url: URL(string: "https://gl/mr/1")!,
        author: "me", headSha: "abc", threads: threads, comments: comments)
}

@Test func markersDecideTheKind() {
    #expect(BotCommentKind.of(ocrFinding) == .finding)
    #expect(BotCommentKind.of(ocrStatus) == .status)
    #expect(BotCommentKind.of(ocrSummary) == .report)
}

@Test func unmarkedCommentsAreFindingsUnlessAShortProgressNote() {
    #expect(BotCommentKind.of("Consider renaming this") == .finding)
    #expect(BotCommentKind.of("Preview build complete", resolvable: false) == .status)
    // inside a thread, or about a problem, or long: still a finding
    #expect(BotCommentKind.of("Preview build complete") == .finding)
    #expect(BotCommentKind.of("Tests passed but coverage dropped 5%", resolvable: false) == .finding)
    #expect(BotCommentKind.of("Scan completed: 3 vulnerabilities", resolvable: false) == .finding)
    #expect(BotCommentKind.of(String(repeating: "review complete ", count: 20), resolvable: false) == .finding)
}

@Test func taggedSeverityIsRead() {
    #expect(BotCommentKind.taggedSeverity("**[test · medium]**") == .medium)
    #expect(BotCommentKind.taggedSeverity("**[security · High]**") == .high)
    #expect(BotCommentKind.taggedSeverity("**[nit · low]** might error") == .low)
    #expect(BotCommentKind.taggedSeverity("no tag") == nil)
    #expect(Classifier.botSeverity("**[nit · low]** this might fail") == .low)
}

@Test func onlyOpenFindingsMakeTheItem() {
    let pr = mr(
        threads: [
            thread(ocrStatus, resolved: true, n: 1), thread(ocrFinding, resolved: false, n: 2),
            thread(ocrFinding, resolved: true, n: 3),
        ],
        comments: [CommentInfo(author: "Open Code Review", isBot: true, body: ocrSummary)])
    let (items, stats) = Classifier.classify(pr)
    let bot = items.first { $0.kind == .botFinding }
    // One open finding, not "2 findings".
    #expect(bot?.headline == "open code review: Add a case for whitespace-only business details.")
    #expect(bot?.severity == .medium)
    #expect(bot?.evidence.count == 2)  // the open finding and the resolved one; no status, no summary
    #expect(stats.noiseComments == 2)  // status + summary
}

@Test func aBotWithOnlyStatusAndReportsMakesNoItem() {
    let pr = mr(
        threads: [thread(ocrStatus, resolved: true, n: 1)],
        comments: [CommentInfo(author: "Open Code Review", isBot: true, body: ocrSummary)])
    let (items, stats) = Classifier.classify(pr)
    #expect(!items.contains { $0.kind == .botFinding })
    #expect(stats.noiseComments == 2)
}

@Test func aNewStatusCommentKeepsTheItemId() {
    let finding = thread(ocrFinding, resolved: false, n: 2)
    let before = Classifier.classify(mr(threads: [finding])).items.first { $0.kind == .botFinding }
    let after = Classifier.classify(mr(threads: [finding, thread(ocrStatus, resolved: true, n: 9)])).items
        .first { $0.kind == .botFinding }
    #expect(before != nil)
    #expect(before?.id == after?.id)
}
