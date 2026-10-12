import Darwin
import Foundation
import Testing

@testable import TriageCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ThreadSupervisorTests {
    @Test func streamsRepeatedTurnsInOneProcessAndWritesRawLog() async throws {
        let fixture = try SupervisorFixture()
        let thread = fixture.thread()
        do {
            try await fixture.supervisor.submit(thread, prompt: "first")
            _ = try await fixture.updates.wait { stateCount($0, thread.id, .idle) == 1 }
            try await fixture.supervisor.submit(thread, prompt: "second")
            let values = try await fixture.updates.wait { stateCount($0, thread.id, .idle) == 2 }
            let messages = assistantTexts(values, thread.id)
            #expect(messages.count == 2)
            #expect(messages[0].split(separator: ":").first == messages[1].split(separator: ":").first)
            #expect(messages[0].contains(":1:--session-id:forwarded:first"))
            #expect(messages[1].contains(":2:--session-id:forwarded:second"))
            #expect(
                values.contains {
                    if case .partial(let id, let text) = $0 { id == thread.id && text == "€" } else { false }
                })
            let log = try WorkbenchStorage.raw(at: fixture.directory.appendingPathComponent("logs"), id: thread.id)
            #expect(log.contains("stream_event"))
            #expect(log.contains("future_field"))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func permissionsQueueAndIdleEvictionResumeSameSession() async throws {
        let fixture = try SupervisorFixture(limit: 1)
        let first = fixture.thread()
        let second = fixture.thread()
        do {
            try await fixture.supervisor.submit(first, prompt: "permission")
            let values = try await fixture.updates.wait { stateCount($0, first.id, .waitingPermission) == 1 }
            let permission = try #require(
                values.compactMap { if case .permission(_, let value) = $0 { value } else { nil } }.first)
            try await fixture.supervisor.submit(second, prompt: "queued turn")
            let queued = try await fixture.updates.wait { stateCount($0, second.id, .queued) == 1 }
            #expect(stateCount(queued, second.id, .starting) == 0)
            try await fixture.supervisor.answer(permission, threadID: first.id, allow: true)
            _ = try await fixture.updates.wait { stateCount($0, second.id, .idle) == 1 }
            var resumedThread = first
            resumedThread.hasSession = true
            try await fixture.supervisor.submit(resumedThread, prompt: "permission")
            let resumed = try await fixture.updates.wait { stateCount($0, first.id, .waitingPermission) == 2 }
            let latest = try #require(
                resumed.compactMap { if case .permission(_, let value) = $0 { value } else { nil } }.last)
            try await fixture.supervisor.answer(latest, threadID: first.id, allow: false)
            let completed = try await fixture.updates.wait { stateCount($0, first.id, .idle) == 2 }
            #expect(assistantTexts(completed, first.id) == ["allow", "deny"])
            #expect(
                completed.contains {
                    if case .raw(let id, let text) = $0 { id == first.id && text.contains("--resume") } else { false }
                })
            await #expect(throws: WorkbenchError.self) {
                try await fixture.supervisor.answer(latest, threadID: first.id, allow: true)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func permissionWriteFailureFailsThreadAndStartsQueuedWork() async throws {
        let fixture = try SupervisorFixture(limit: 1)
        let first = fixture.thread(), second = fixture.thread()
        do {
            try await fixture.supervisor.submit(first, prompt: "closed-permission-input")
            let values = try await fixture.updates.wait { stateCount($0, first.id, .waitingPermission) == 1 }
            let permission = try #require(
                values.compactMap { if case .permission(_, let value) = $0 { value } else { nil } }.first)
            try await fixture.supervisor.submit(second, prompt: "next")
            await #expect(throws: Subprocess.SessionError.self) {
                try await fixture.supervisor.answer(permission, threadID: first.id, allow: true)
            }
            let completed = try await fixture.updates.wait { stateCount($0, second.id, .idle) == 1 }
            #expect(stateCount(completed, first.id, .failed) == 1)
            #expect(
                completed.contains {
                    if case .message(let id, let message) = $0 {
                        id == first.id && message.kind == .error && !message.text.isEmpty
                    } else {
                        false
                    }
                })
            await #expect(throws: WorkbenchError.self) {
                try await fixture.supervisor.answer(permission, threadID: first.id, allow: true)
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test(arguments: ["malformed", "wrong-session"])
    func rejectsMalformedAndWrongSessionOutput(prompt: String) async throws {
        let fixture = try SupervisorFixture()
        let thread = fixture.thread()
        do {
            try await fixture.supervisor.submit(thread, prompt: prompt)
            let values = try await fixture.updates.wait { stateCount($0, thread.id, .failed) == 1 }
            let errors = values.compactMap {
                if case .message(_, let message) = $0, message.kind == .error { message.text } else { nil }
            }
            // Failure and diagnostic are separate stream updates.
            let diagnosed =
                errors.isEmpty
                ? try await fixture.updates.wait {
                    $0.contains { if case .message(_, let message) = $0 { message.kind == .error } else { false } }
                } : values
            #expect(stateCount(diagnosed, thread.id, .idle) == 0)
            if prompt == "wrong-session" {
                #expect(
                    diagnosed.contains {
                        if case .message(_, let message) = $0 {
                            message.text.contains("unexpected session ID")
                        } else {
                            false
                        }
                    })
            }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test(arguments: ["ignore-eof", "delayed-stop", "startup-stop"])
    func retiringChildrenHoldTheirSlotsUntilExit(prompt: String) async throws {
        let fixture = try SupervisorFixture(limit: 1)
        let first = fixture.thread(), second = fixture.thread()
        do {
            try await fixture.supervisor.submit(first, prompt: prompt)
            if prompt == "ignore-eof" {
                _ = try await fixture.updates.wait { stateCount($0, first.id, .idle) == 1 }
            } else if prompt == "delayed-stop" {
                _ = try await fixture.updates.wait {
                    $0.contains { if case .partial(let id, _) = $0 { id == first.id } else { false } }
                }
            }
            if prompt != "ignore-eof" { await fixture.supervisor.stop(first.id) }
            try await fixture.supervisor.submit(second, prompt: "next")
            let values = try await fixture.updates.wait { stateCount($0, second.id, .idle) == 1 }
            #expect(stateCount(values, first.id, .failed) == 0)
            let log = try String(
                contentsOf: fixture.directory.appendingPathComponent("fixture-children.jsonl"), encoding: .utf8)
            let entries = try log.split(separator: "\n").map {
                try JSONDecoder().decode(StreamJSON.self, from: Data($0.utf8))
            }
            #expect(!entries.isEmpty)
            #expect(entries.allSatisfy { !$0["overlap"].flag })
            if prompt != "startup-stop" { #expect(entries.count == 2) }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func resumeImmediatelyAfterStopWaitsForRetiringSession() async throws {
        let fixture = try SupervisorFixture(limit: 1)
        var thread = fixture.thread()
        let threadID = thread.id
        do {
            try await fixture.supervisor.submit(thread, prompt: "delayed-stop")
            _ = try await fixture.updates.wait {
                $0.contains { if case .partial(let id, _) = $0 { id == threadID } else { false } }
            }
            await fixture.supervisor.stop(thread.id)
            thread.hasSession = true
            try await fixture.supervisor.submit(thread, prompt: "resumed")
            let values = try await fixture.updates.wait { stateCount($0, threadID, .idle) == 1 }
            #expect(stateCount(values, thread.id, .interrupted) == 1)
            #expect(stateCount(values, thread.id, .failed) == 0)
            #expect(assistantTexts(values, thread.id).last?.contains("--resume:forwarded:resumed") == true)
            let log = try String(
                contentsOf: fixture.directory.appendingPathComponent("fixture-children.jsonl"), encoding: .utf8)
            #expect(!log.contains("\"overlap\": true"))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test(arguments: ["wait", "startup-stop"])
    func shutdownWaitsForChildrenIncludingStartupReservations(prompt: String) async throws {
        let fixture = try SupervisorFixture(limit: 1)
        let thread = fixture.thread()
        do {
            try await fixture.supervisor.submit(thread, prompt: prompt)
            if prompt == "wait" {
                _ = try await fixture.updates.wait {
                    $0.contains { if case .partial(let id, _) = $0 { id == thread.id } else { false } }
                }
            }
            await fixture.supervisor.shutdown()
            let path = fixture.directory.appendingPathComponent("fixture-children.jsonl")
            if FileManager.default.fileExists(atPath: path.path) {
                let log = try String(contentsOf: path, encoding: .utf8)
                for line in log.split(separator: "\n") {
                    let entry = try JSONDecoder().decode(StreamJSON.self, from: Data(line.utf8))
                    guard case .number(let pid) = entry["pid"] else {
                        Issue.record("Fixture did not record its PID")
                        continue
                    }
                    #expect(kill(Int32(pid), 0) == -1)
                    #expect(errno == ESRCH)
                }
            }
            await #expect(throws: WorkbenchError.self) { try await fixture.supervisor.submit(thread, prompt: "late") }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func stoppingBusyThreadPumpsQueueAndRejectsFurtherSubmitAfterShutdown() async throws {
        let fixture = try SupervisorFixture(limit: 1)
        let first = fixture.thread(), second = fixture.thread()
        do {
            try await fixture.supervisor.submit(first, prompt: "wait")
            _ = try await fixture.updates.wait {
                $0.contains { if case .partial(let id, _) = $0 { id == first.id } else { false } }
            }
            try await fixture.supervisor.submit(second, prompt: "next")
            await fixture.supervisor.stop(first.id)
            let values = try await fixture.updates.wait { stateCount($0, second.id, .idle) == 1 }
            #expect(stateCount(values, first.id, .interrupted) == 1)
            await fixture.supervisor.shutdown()
            await #expect(throws: WorkbenchError.self) { try await fixture.supervisor.submit(first, prompt: "late") }
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}
