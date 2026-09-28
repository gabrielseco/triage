import Foundation

/// Where a PR's checks stand, for the badge in the item detail.
public struct CIStatus: Equatable, Sendable {
    public enum State: Sendable { case failing, running, passed }

    public var failed: Int
    public var running: Int
    /// Succeeded, or neutral (skipped, cancelled), which doesn't block a merge.
    public var passed: Int

    public var total: Int { failed + running + passed }

    /// Failing wins over running: a red check won't turn green by waiting.
    public var state: State { failed > 0 ? .failing : running > 0 ? .running : .passed }

    public var label: String {
        switch state {
        case .failing: running > 0 ? "\(failed) failing · \(running) running" : "\(failed) of \(total) failing"
        case .running: "\(running) of \(total) running"
        case .passed: total == 1 ? "Check passed" : "All \(total) checks passed"
        }
    }
}

extension PullRequest {
    /// Nil when the head commit has no checks at all.
    public var ciStatus: CIStatus? {
        guard !checks.isEmpty else { return nil }
        let count = { (s: CheckState) in checks.filter { $0.state == s }.count }
        return CIStatus(failed: count(.failure), running: count(.pending), passed: count(.success) + count(.neutral))
    }

    /// The PR's Checks tab on GitHub, its Pipelines tab on GitLab.
    public var checksURL: URL {
        switch repo.forge {
        case .github: url.appendingPathComponent("checks")
        case .gitlab: url.appendingPathComponent("pipelines")
        }
    }
}
