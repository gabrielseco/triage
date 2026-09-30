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

private let now = Date(timeIntervalSince1970: 1_000_000)

private func started(_ items: [AttentionItem] = [], seen: Date = now) -> ReviewRequestAlertState {
    var s = ReviewRequestAlertState()
    s.started = true
    for item in items { s.notified[item.id] = .init(prID: item.pr.id, lastSeen: seen) }
    return s
}

private func plan(
    open: [AttentionItem], active: [AttentionItem]? = nil, fetched: [AttentionItem]? = nil,
    state: ReviewRequestAlertState, at time: Date = now, complete: Bool = true
) -> (alerts: [ReviewRequestAlert], state: ReviewRequestAlertState) {
    let refresh = ReviewRequestAlerts.Refresh(
        open: open, active: active ?? open, fetched: Set((fetched ?? open).map(\.pr.id)), complete: complete)
    return ReviewRequestAlerts.plan(refresh, state: state, now: time)
}

@Test func theFirstRefreshRecordsWhatsWaitingWithoutBanners() {
    let open = [request(1), request(2)]
    let (alerts, state) = plan(open: open, state: ReviewRequestAlertState())
    #expect(alerts.isEmpty)
    #expect(state.started)
    #expect(Set(state.notified.keys) == Set(open.map(\.id)))
}

@Test func anIncompleteFirstRefreshDoesntStartTheClock() {
    let (alerts, state) = plan(open: [request(1)], state: ReviewRequestAlertState(), complete: false)
    #expect(alerts.isEmpty)
    #expect(!state.started)
    #expect(Set(state.notified.keys) == [request(1).id])
}

@Test func aNewRequestNotifiesOnce() {
    let open = [request(1), request(2)]
    let (alerts, state) = plan(open: open, state: started([request(1)]))
    #expect(alerts == [.new(request(2))])
    #expect(alerts[0].title == "Review requested: web !2")
    #expect(alerts[0].subtitle == "by rita")
    #expect(alerts[0].body == "Add thing 2")
    #expect(plan(open: open, state: state).alerts.isEmpty)
}

@Test func aHiddenRequestDoesntNotify() {
    let (alerts, state) = plan(open: [request(1)], active: [], state: started())
    #expect(alerts.isEmpty)
    // Remembered, so showing it again isn't news either.
    #expect(plan(open: [request(1)], state: state).alerts.isEmpty)
}

@Test func aReviewedRequestIsForgottenSoAskingAgainNotifies() {
    // The PR came back without the request.
    let (_, state) = plan(open: [], fetched: [request(1)], state: started([request(1)]))
    #expect(state.notified.isEmpty)
    #expect(plan(open: [request(1)], state: state).alerts == [.new(request(1))])
}

@Test func aPRMissingFromOneRefreshKeepsItsRequest() {
    // Its repo or its merge request failed to load: not reviewed, just not fetched.
    let (_, state) = plan(open: [], fetched: [], state: started([request(1)]))
    #expect(Set(state.notified.keys) == [request(1).id])
    #expect(plan(open: [request(1)], state: state).alerts.isEmpty)
}

@Test func aRequestUnseenForADayIsForgotten() {
    let old = started([request(1)], seen: now.addingTimeInterval(-ReviewRequestAlerts.forgetAfter))
    #expect(plan(open: [], fetched: [], state: old).state.notified.isEmpty)
}

@Test func manyNewRequestsAtOnceAreOneSummary() {
    let open = (1...4).map(request)
    let (alerts, state) = plan(open: open, state: started())
    #expect(alerts == [.summary(count: 4)])
    #expect(alerts[0].item == nil)
    #expect(alerts[0].title == "4 reviews requested")
    #expect(state.notified.count == 4)
}
