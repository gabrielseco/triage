import Foundation
import Testing

@testable import TriageCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let hour: TimeInterval = 3600

private func ping(_ n: Int, kind: LinearPing.Kind = .threadReply, at: Date = t0) -> LinearPing {
    LinearPing(
        id: "linear:ENG-\(n):root:c\(n)", kind: kind, issueKey: "ENG-\(n)", issueTitle: "Migrate billing",
        author: "Alice Smith", authorAvatar: nil, excerpt: "can you confirm?", body: "can you confirm?",
        url: URL(string: "https://linear.app/acme/issue/ENG-\(n)#comment-c\(n)") ?? URL(fileURLWithPath: "/"),
        pingedAt: at, threadID: "ENG-\(n):root")
}

/// A state that has already done its first run.
private var started: PingAlertState {
    var s = PingAlertState()
    s.started = true
    return s
}

@Suite struct PingAlertsTests {
    @Test func firstRunRecordsWhatIsThereWithoutBanners() {
        let (alerts, state) = PingAlerts.plan(
            open: [ping(1), ping(2)], active: [ping(1), ping(2)], state: .init(), now: t0)
        #expect(alerts.isEmpty)
        #expect(state.started)
        #expect(state.notified.count == 2)
        // And those don't come back as reminders an hour later as if they were new.
        let later = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: state, now: t0 + hour)
        #expect(later.alerts == [.reminder(ping(1), since: hour)])
    }

    @Test func aNewPingNotifiesOnce() {
        let first = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: started, now: t0)
        #expect(first.alerts == [.new(ping(1))])
        let again = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: first.state, now: t0 + 30)
        #expect(again.alerts.isEmpty)
    }

    @Test func remindsAt1hAnd4hThenDaily() {
        var state = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: started, now: t0).state
        var reminders: [TimeInterval] = []
        // A poll every 30 minutes for three days.
        for step in 1...(3 * 48) {
            let now = t0 + Double(step) * 1800
            let r = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: state, now: now)
            state = r.state
            if case .reminder = r.alerts.first { reminders.append(now.timeIntervalSince(t0) / hour) }
        }
        #expect(reminders == [1, 4, 28, 52])
    }

    @Test func overdueRemindersCollapseIntoOne() {
        let state = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: started, now: t0).state
        // Snoozed until tomorrow, or the Mac was asleep: one reminder, then the schedule carries on.
        let back = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: state, now: t0 + 24 * hour)
        #expect(back.alerts == [.reminder(ping(1), since: 24 * hour)])
        let soon = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: back.state, now: t0 + 25 * hour)
        #expect(soon.alerts.isEmpty)
    }

    @Test func dismissedOrSnoozedPingsDontRemindAndAreRemembered() {
        let state = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: started, now: t0).state
        let hidden = PingAlerts.plan(open: [ping(1)], active: [], state: state, now: t0 + 2 * hour)
        #expect(hidden.alerts.isEmpty)
        #expect(hidden.state.notified[ping(1).id] != nil)
    }

    @Test func answeredPingsAreForgotten() {
        let state = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: started, now: t0).state
        let answered = PingAlerts.plan(open: [], active: [], state: state, now: t0 + 2 * hour)
        #expect(answered.alerts.isEmpty)
        #expect(answered.state.notified.isEmpty)
    }

    @Test func manyNewPingsAtOnceBecomeOneSummary() {
        let pings = (1...5).map { ping($0, at: t0 + Double($0)) }
        let r = PingAlerts.plan(open: pings, active: pings, state: started, now: t0 + 10)
        #expect(r.alerts == [.summary(count: 5, newest: ping(5, at: t0 + 5))])
        #expect(r.state.notified.count == 5)

        let three = Array(pings.prefix(3))
        #expect(PingAlerts.plan(open: three, active: three, state: started, now: t0).alerts.count == 3)
    }

    @Test func content() {
        #expect(PingAlert.new(ping(1)).title == "Alice Smith replied in your thread")
        #expect(PingAlert.new(ping(1)).subtitle == "ENG-1 · Migrate billing")
        #expect(PingAlert.new(ping(1)).body == "can you confirm?")
        #expect(PingAlert.new(ping(1)).threadIdentifier == "linear:ENG-1")
        #expect(PingAlert.reminder(ping(1), since: hour).title == "Still waiting: Alice Smith replied in your thread")
        #expect(PingAlert.reminder(ping(1), since: 30 * hour).subtitle == "ENG-1 · 1 d ago")
        #expect(PingAlert.summary(count: 5, newest: ping(2)).title == "5 new Linear pings")
        #expect(PingAlert.summary(count: 5, newest: ping(2)).ping == nil)
        #expect(PingAlert.new(ping(1)).ping == ping(1))
    }

    @Test func stateRoundTripsThroughJSON() throws {
        let state = PingAlerts.plan(open: [ping(1)], active: [ping(1)], state: started, now: t0).state
        let decoded = try JSONDecoder().decode(PingAlertState.self, from: try JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}
