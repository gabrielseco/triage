import Foundation
import Testing

@testable import TriageCore

@Suite(.timeLimit(.minutes(1)))
struct ThreadSupervisorPolicyTests {
    @Test func policyAnswersAllowedCallsWithoutPrompting() async throws {
        let fixture = try SupervisorFixture()
        let thread = fixture.thread()
        do {
            let policy = PermissionPolicy(preset: .readOnly, worktree: thread.worktree)
            try await fixture.supervisor.submit(thread, prompt: "policy-allowed", policy: policy)
            let values = try await fixture.updates.wait { stateCount($0, thread.id, .idle) == 1 }
            #expect(assistantTexts(values, thread.id) == ["allow"])
            #expect(stateCount(values, thread.id, .waitingPermission) == 0)
            #expect(!values.contains { if case .permission = $0 { true } else { false } })
            #expect(
                values.contains {
                    if case .message(_, let message) = $0 {
                        message.kind == .step && message.text == "Auto-allowed: Bash `git status` (Read-only auto)"
                    } else {
                        false
                    }
                })
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test(arguments: [
        ("policy-prompted", PermissionPreset.readOnly), ("policy-allowed", PermissionPreset.ask),
        ("policy-guardrail", PermissionPreset.workflow),
    ])
    func policyStillPromptsForEverythingElse(prompt: String, preset: PermissionPreset) async throws {
        let fixture = try SupervisorFixture()
        let thread = fixture.thread()
        do {
            // The rule for rm shows a stored rule cannot lift a guardrail.
            let policy = PermissionPolicy(
                preset: preset, rules: ["Bash(rm:*)"], worktree: thread.worktree, workflowCommands: ["rm"])
            try await fixture.supervisor.submit(thread, prompt: prompt, policy: policy)
            let values = try await fixture.updates.wait { stateCount($0, thread.id, .waitingPermission) == 1 }
            let permission = try #require(
                values.compactMap { if case .permission(_, let value) = $0 { value } else { nil } }.first)
            #expect(assistantTexts(values, thread.id).isEmpty)
            try await fixture.supervisor.answer(permission, threadID: thread.id, allow: false)
            let completed = try await fixture.updates.wait { stateCount($0, thread.id, .idle) == 1 }
            #expect(assistantTexts(completed, thread.id) == ["deny"])
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func updatedPolicyAppliesToLaterRequestsOfALiveThread() async throws {
        let fixture = try SupervisorFixture()
        let thread = fixture.thread()
        do {
            let asking = PermissionPolicy(preset: .ask, worktree: thread.worktree)
            try await fixture.supervisor.submit(thread, prompt: "policy-prompted", policy: asking)
            let values = try await fixture.updates.wait { stateCount($0, thread.id, .waitingPermission) == 1 }
            let permission = try #require(
                values.compactMap { if case .permission(_, let value) = $0 { value } else { nil } }.first)
            try await fixture.supervisor.answer(permission, threadID: thread.id, allow: true)
            _ = try await fixture.updates.wait { stateCount($0, thread.id, .idle) == 1 }
            await fixture.supervisor.setPolicy(
                PermissionPolicy(preset: .ask, rules: ["Bash(swift test:*)"], worktree: thread.worktree),
                for: thread.id)
            try await fixture.supervisor.submit(
                thread, prompt: "policy-prompted",
                policy: PermissionPolicy(preset: .ask, rules: ["Bash(swift test:*)"], worktree: thread.worktree))
            let completed = try await fixture.updates.wait { stateCount($0, thread.id, .idle) == 2 }
            #expect(stateCount(completed, thread.id, .waitingPermission) == 1)
            #expect(assistantTexts(completed, thread.id) == ["allow", "allow"])
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}
