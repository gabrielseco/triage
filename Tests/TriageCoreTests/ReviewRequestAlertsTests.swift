import Foundation
import Testing

@testable import TriageCore

private func request(_ number: Int) -> AttentionItem {
    let repo = RepoRef(gitlabPath: "acme/web", host: "gitlab.com")!
    let pr = PullRequest(
        repo: repo, number: number, title: "Add thing \(number)",
        url: URL(string: "https://gitlab.com/acme/web/-/merge_requests/\(number)")!, author: "rita",
        updatedAt: Date(timeIntervalSince1970: 0), headSha: "abc", requestedReviewers: ["me"])
    return Classifier.classify(pr, viewer: "me").items[0]
}

private func started(_ ids: Set<String> = []) -> ReviewRequestAlertState {
    var s = ReviewRequestAlertState()
    s.started = true
    s.notified = ids
    return s
}

@Test func theFirstRefreshRecordsWhatsWaitingWithoutBanners() {
    let open = [request(1), request(2)]
    let (alerts, state) = ReviewRequestAlerts.plan(
        open: open, active: open, state: ReviewRequestAlertState(), complete: true)
    #expect(alerts.isEmpty)
    #expect(state.started)
    #expect(state.notified == Set(open.map(\.id)))
}

@Test func anIncompleteFirstRefreshDoesntStartTheClock() {
    let (alerts, state) = ReviewRequestAlerts.plan(
        open: [request(1)], active: [request(1)], state: ReviewRequestAlertState(), complete: false)
    #expect(alerts.isEmpty)
    #expect(!state.started)
    #expect(state.notified == [request(1).id])
}

@Test func aNewRequestNotifiesOnce() {
    let open = [request(1), request(2)]
    let (alerts, state) = ReviewRequestAlerts.plan(
        open: open, active: open, state: started([request(1).id]), complete: true)
    #expect(alerts == [.new(request(2))])
    #expect(alerts[0].title == "Review requested: web !2")
    #expect(alerts[0].subtitle == "by rita")
    #expect(alerts[0].body == "Add thing 2")
    #expect(ReviewRequestAlerts.plan(open: open, active: open, state: state, complete: true).alerts.isEmpty)
}

@Test func aHiddenRequestDoesntNotifyUntilItsRestored() {
    let (alerts, state) = ReviewRequestAlerts.plan(
        open: [request(1)], active: [], state: started(), complete: true)
    #expect(alerts.isEmpty)
    #expect(state.notified.isEmpty)
    // Restored later: it's still new, so it notifies then.
    #expect(
        ReviewRequestAlerts.plan(open: [request(1)], active: [request(1)], state: state, complete: true).alerts
            == [.new(request(1))])
}

@Test func aReviewedRequestIsForgottenSoAskingAgainNotifies() {
    let (_, state) = ReviewRequestAlerts.plan(open: [], active: [], state: started([request(1).id]), complete: true)
    #expect(state.notified.isEmpty)
}

@Test func aFailedRepoDoesntMakeItsRequestsNotifyAgain() {
    let (_, state) = ReviewRequestAlerts.plan(open: [], active: [], state: started([request(1).id]), complete: false)
    #expect(state.notified == [request(1).id])
}

@Test func manyNewRequestsAtOnceAreOneSummary() {
    let open = (1...4).map(request)
    let (alerts, state) = ReviewRequestAlerts.plan(open: open, active: open, state: started(), complete: true)
    #expect(alerts == [.summary(count: 4)])
    #expect(alerts[0].item == nil)
    #expect(alerts[0].title == "4 reviews requested")
    #expect(state.notified.count == 4)
}
