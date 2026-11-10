import Foundation
import TriageCore

/// Explain, fix and report on review threads through Workbench (`ThreadWorkbench.swift`). Each is one explicit
/// step: explaining changes nothing, Fix pushes and replies, Resolve is its own button, and dismissing as a false
/// positive stays on this Mac.
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

    /// The state to show for the thread: the forge's, or "False positive" for an open one you dismissed.
    func threadState(_ threadID: String, in item: AttentionItem) -> ThreadState? {
        thread(threadID, in: item).map { threadTriage.state(of: $0, in: item.pr) }
    }

    func threadExplanation(_ threadID: String, in item: AttentionItem) -> ThreadExplanationStatus {
        threadTriage.status(of: threadID, head: item.pr.headSha, running: threadBusy.contains(threadID))
    }

    /// Whether Workbench can work on this PR's threads: the forge needs a checkout, which a GitHub PR has.
    func canWorkOnThreads(_ pr: PullRequest) -> Bool { can(.checkout, pr) && can(.threads, pr) }

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

    private func actions(_ pr: PullRequest, _ id: String) async -> ThreadActions? {
        guard let workbench = await workbench(for: pr, id) else { return nil }
        do { return ThreadActions(workbench: workbench, forge: try await forgeClient(pr.repo.forge)) } catch {
            threadStatus[id] = error.localizedDescription
            return nil
        }
    }

    func explainThread(_ threadID: String, in item: AttentionItem) async {
        guard !threadBusy.contains(threadID) else { return }
        let ref = threadRef(threadID, in: item)
        threadBusy.insert(threadID)
        defer { threadBusy.remove(threadID) }
        threadStatus[threadID] = "Workbench is explaining this thread… this can take a few minutes."
        guard let actions = await actions(item.pr, threadID) else { return }
        do {
            let explanation = try await actions.explain(ref)
            threadTriage.store(explanation, for: ref)
            threadStatus[threadID] = nil
        } catch {
            threadStatus[threadID] = "Couldn't explain the thread: \(error.localizedDescription)"
        }
    }

    /// Pushes the fix and replies "Fixed in <sha>" on the thread, then refreshes so the thread reads the reply.
    /// Runs only from the Fix button, once, for this thread.
    func fixThread(_ threadID: String, in item: AttentionItem) async {
        guard !threadBusy.contains(threadID) else { return }
        let ref = threadRef(threadID, in: item)
        threadBusy.insert(threadID)
        threadStatus[threadID] = "Workbench is fixing and pushing… this can take a few minutes."
        guard let actions = await actions(item.pr, threadID) else {
            threadBusy.remove(threadID)
            return
        }
        do {
            let out = try await actions.fix(ref) { text in
                Task { @MainActor in self.threadStatus[threadID] = "Replying “\(text)”…" }
            }
            threadStatus[threadID] = "Replied “\(out.reply)” on the thread."
            threadBusy.remove(threadID)
            await refresh()
        } catch {
            threadStatus[threadID] = "Couldn't fix the thread: \(error.localizedDescription)"
            threadBusy.remove(threadID)
        }
    }

    func dismissThreadAsFalsePositive(_ threadID: String) {
        threadTriage.dismissAsFalsePositive(threadID)
        threadStatus[threadID] = nil
    }

    func restoreThread(_ threadID: String) { threadTriage.restore(threadID) }

    /// Resolves the thread on the forge. Never called by anything but the Resolve button.
    func resolveThread(_ threadID: String, in item: AttentionItem) async {
        guard !threadBusy.contains(threadID) else { return }
        threadBusy.insert(threadID)
        defer { threadBusy.remove(threadID) }
        threadStatus[threadID] = "Resolving…"
        do {
            try await forgeClient(item.pr.repo.forge).resolveThread(item.pr, threadID: threadID)
            threadStatus[threadID] = nil
            await refresh()
        } catch {
            threadStatus[threadID] = "Couldn't resolve the thread: \(error.localizedDescription)"
        }
    }
}
