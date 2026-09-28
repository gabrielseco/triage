import Foundation
import Testing

@testable import TriageCore

private func pr(_ checks: [CheckState]) -> PullRequest {
    PullRequest(
        repo: RepoRef(owner: "acme", name: "web"), number: 7, title: "t",
        url: URL(string: "https://github.com/acme/web/pull/7")!, author: "me", headSha: "a",
        checks: checks.enumerated().map { CheckInfo(name: "c\($0.offset)", state: $0.element) })
}

@Test func noChecksHasNoStatus() {
    #expect(pr([]).ciStatus == nil)
}

@Test func allGreenCountsNeutralAsPassed() {
    let s = pr([.success, .neutral, .success]).ciStatus
    #expect(s?.state == .passed)
    #expect(s?.label == "All 3 checks passed")
    #expect(pr([.success]).ciStatus?.label == "Check passed")
}

@Test func runningShowsHowManyOfTotal() {
    let s = pr([.success, .pending, .pending]).ciStatus
    #expect(s?.state == .running)
    #expect(s?.label == "2 of 3 running")
}

@Test func failingWinsOverRunning() {
    #expect(pr([.failure, .pending, .success]).ciStatus?.state == .failing)
    #expect(pr([.failure, .pending, .success]).ciStatus?.label == "1 failing · 1 running")
    #expect(pr([.failure, .failure, .success]).ciStatus?.label == "2 of 3 failing")
}

@Test func checksURLIsTheChecksTab() {
    #expect(pr([]).checksURL.absoluteString == "https://github.com/acme/web/pull/7/checks")
}
