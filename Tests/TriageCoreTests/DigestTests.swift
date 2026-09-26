import Foundation
import Testing

@testable import TriageCore

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Madrid")!
    return c
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func item(_ n: Int, _ kind: AttentionKind = .ciFailure, _ sev: Severity = .high) -> AttentionItem {
    let pr = PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: n, title: "t",
        url: URL(string: "https://github.com/acme/web/pull/\(n)")!, author: "a", headSha: "s")
    return AttentionItem(id: "\(n)|\(kind)", kind: kind, severity: sev, pr: pr, headline: "h\(n)", evidence: [])
}

// 2026-09-28 is a Monday.
@Test func slotIsLatestPastHourToday() {
    #expect(
        DigestBuilder.latestSlot(
            atOrBefore: date(2026, 9, 28, 14, 5), hours: [12, 18], weekdaysOnly: true, calendar: cal)
            == date(2026, 9, 28, 12))
    #expect(
        DigestBuilder.latestSlot(
            atOrBefore: date(2026, 9, 29, 18, 0), hours: [12, 18], weekdaysOnly: true, calendar: cal)
            == date(2026, 9, 29, 18))
}

@Test func mondayMorningFallsBackToFridayWhenWeekdaysOnly() {
    let monday9 = date(2026, 9, 28, 9)
    #expect(
        DigestBuilder.latestSlot(atOrBefore: monday9, hours: [12, 18], weekdaysOnly: true, calendar: cal)
            == date(2026, 9, 25, 18))
    #expect(
        DigestBuilder.latestSlot(atOrBefore: monday9, hours: [12, 18], weekdaysOnly: false, calendar: cal)
            == date(2026, 9, 27, 18))
}

@Test func digestReportsOnlyNewItemsAndCountsCleared() {
    let d = DigestBuilder.build(
        current: [item(1), item(2, .botFinding, .low), item(3, .mergeConflict)],
        previousIDs: [item(1).id, "gone|x", "gone|y"], since: nil, calendar: cal)
    #expect(d.newItems.map(\.pr.number) == [3, 2])  // severity order
    #expect(d.clearedCount == 2)
    #expect(d.title == "2 new")
    #expect(d.body.hasSuffix("3 open · 2 cleared"))
}

@Test func quietDigestSaysSo() {
    let d = DigestBuilder.build(current: [item(1)], previousIDs: [item(1).id], since: nil, calendar: cal)
    #expect(d.newItems.isEmpty)
    #expect(d.title == "Nothing new")
    #expect(d.body == "1 open")
}

@Test func longDigestIsCapped() {
    let d = DigestBuilder.build(current: (1...6).map { item($0) }, previousIDs: [], since: nil, calendar: cal)
    #expect(d.body.contains("+3 more"))
    #expect(d.body.components(separatedBy: "\n").count == 5)
}

@Test func waitingForReviewNeverMakesADigest() {
    let waiting = item(3, .awaitingReview, .info)
    let d = DigestBuilder.build(current: [item(1), waiting], previousIDs: [item(1).id], since: nil, calendar: cal)
    #expect(d.newItems.isEmpty)
    #expect(d.openCount == 1)
    #expect(d.trackedIDs == [item(1).id])
    // It never enters the baseline, so a waiting PR going away doesn't count as cleared either.
    let later = DigestBuilder.build(current: [item(1)], previousIDs: d.trackedIDs, since: nil, calendar: cal)
    #expect(later.clearedCount == 0)
}
