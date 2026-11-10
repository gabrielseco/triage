import Foundation

/// A Workbench that runs nothing; see `MockWorld.threadWorkbench()`.
struct MockThreadWorkbench: ThreadWorkbench {
    func explain(_ thread: ThreadRef) async throws -> ThreadExplanation {
        ThreadExplanation(
            reasoning: "The reviewer's point holds: this code path can run with a value it does not expect.",
            proposedFix: "Guard the value before it is used, and add a test for the case it missed.")
    }
}
