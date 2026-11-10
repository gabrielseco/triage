import Foundation

/// A Workbench that runs nothing; see `MockWorld.threadWorkbench()`.
struct MockThreadWorkbench: ThreadWorkbench {
    let store: MockStore
    let viewer: String

    func explain(_ thread: ThreadRef) async throws -> ThreadExplanation {
        ThreadExplanation(
            reasoning: "The reviewer's point holds: this code path can run with a value it does not expect.",
            proposedFix: "Guard the value before it is used, and add a test for the case it missed.")
    }

    func fix(_ thread: ThreadRef) async throws -> String {
        let commit = MockWorld.stableSha("fix:\(thread.threadID)")
        guard store.push(commit, to: thread.threadID) else { throw MockError.invalid("no thread \(thread.threadID)") }
        return commit
    }

    func reply(_ thread: ThreadRef, body: String) async throws {
        guard store.reply(to: thread.threadID, as: viewer, body: body) else {
            throw MockError.invalid("no thread \(thread.threadID)")
        }
    }
}
