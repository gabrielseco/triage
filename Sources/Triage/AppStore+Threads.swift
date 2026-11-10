import Foundation
import TriageCore

/// Explain review threads through Workbench (`ThreadWorkbench.swift`). Explaining changes nothing on the forge.
struct ThreadProgress {
    var busy: Set<String> = []
    var status: [String: String] = [:]
}

extension AppStore {
    var threadBusy: Set<String> {
        get { threadProgress.busy }
        set { threadProgress.busy = newValue }
    }
    var threadStatus: [String: String] {
        get { threadProgress.status }
        set { threadProgress.status = newValue }
    }

    func thread(_ threadID: String, in item: AttentionItem) -> ReviewThreadInfo? {
        item.pr.threads.first { $0.id == threadID }
    }

    func threadRef(_ threadID: String, in item: AttentionItem) -> ThreadRef {
        ThreadRef(repo: item.pr.repo, number: item.pr.number, threadID: threadID, head: item.pr.headSha)
    }

    func threadExplanation(_ threadID: String, in item: AttentionItem) -> ThreadExplanationStatus {
        threadTriage.status(of: threadID, head: item.pr.headSha, running: threadBusy.contains(threadID))
    }

    /// Whether Workbench can work on this PR's threads: the forge needs a checkout, which a GitHub PR has.
    func canWorkOnThreads(_ pr: PullRequest) -> Bool { can(.checkout, pr) }

    private func workbench(for pr: PullRequest, _ id: String) async -> (any ThreadWorkbench)? {
        if let mock = MockMode.world { return mock.threadWorkbench() }
        guard let workbench = ExplainPR.findWorkbench(setting: workbenchPath) else {
            threadStatus[id] = ExplainPR.Failure.workbenchNotFound.localizedDescription
            return nil
        }
        guard let checkout = await checkoutPath(for: pr.repo) ?? chooseCheckout(for: pr.repo) else {
            threadStatus[id] = "No local checkout of \(pr.repo.fullName): right-click the repo in the sidebar."
            return nil
        }
        return CLIThreadWorkbench(workbench: workbench, checkout: checkout)
    }

    func explainThread(_ threadID: String, in item: AttentionItem) async {
        guard !threadBusy.contains(threadID) else { return }
        let ref = threadRef(threadID, in: item)
        threadBusy.insert(threadID)
        defer { threadBusy.remove(threadID) }
        threadStatus[threadID] = "Workbench is explaining this thread… this can take a few minutes."
        guard let workbench = await workbench(for: item.pr, threadID) else { return }
        do {
            let explanation = try await workbench.explain(ref)
            threadTriage.store(explanation, for: ref)
            threadStatus[threadID] = nil
        } catch {
            threadStatus[threadID] = "Couldn't explain the thread: \(error.localizedDescription)"
        }
    }
}
