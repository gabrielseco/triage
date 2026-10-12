import Darwin
import Foundation
import Testing

@testable import TriageCore

private actor ThreadUpdates {
    private var values: [WorkbenchUpdate] = []
    func append(_ update: WorkbenchUpdate) { values.append(update) }
    func snapshot() -> [WorkbenchUpdate] { values }

    func wait(_ predicate: @Sendable ([WorkbenchUpdate]) -> Bool) async throws -> [WorkbenchUpdate] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate(values) { return values }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkbenchError("Timed out waiting for scripted thread updates")
    }
}

private func stateCount(_ values: [WorkbenchUpdate], _ id: UUID, _ state: WorkbenchState) -> Int {
    values.filter { if case .state(let thread, let value) = $0 { thread == id && value == state } else { false } }.count
}

private func assistantTexts(_ values: [WorkbenchUpdate], _ id: UUID) -> [String] {
    values.compactMap {
        if case .message(let thread, let message) = $0, thread == id, message.kind == .assistant {
            message.text
        } else {
            nil
        }
    }
}

private struct SupervisorFixture {
    let directory: URL
    let supervisor: ThreadSupervisor
    let updates: ThreadUpdates
    let observer: Task<Void, Never>

    init(limit: Int = 2) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("scripted backend.py")
        try Data(Self.script.utf8).write(to: script)
        supervisor = ThreadSupervisor(
            limit: limit, executable: "/usr/bin/python3", prefix: [script.path],
            environment: ["FIXTURE_VALUE": "forwarded"], logDirectory: directory.appendingPathComponent("logs"))
        let updates = ThreadUpdates()
        self.updates = updates
        let stream = supervisor.events
        observer = Task { for await update in stream { await updates.append(update) } }
    }

    func thread(hasSession: Bool = false) -> WorkbenchThread {
        WorkbenchThread(
            projectID: UUID(), title: "Fixture", worktree: directory.path, branch: "fixture",
            hasSession: hasSession, model: "fixture-model")
    }

    func close() async {
        await supervisor.shutdown()
        observer.cancel()
        await observer.value
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
        import json, os, sys, time
        children_path = 'fixture-children.jsonl'
        overlap = False
        if os.path.exists(children_path):
            for entry in open(children_path):
                try:
                    os.kill(json.loads(entry)['pid'], 0)
                    overlap = True
                except ProcessLookupError:
                    pass
        with open(children_path, 'a') as children:
            children.write(json.dumps({'pid': os.getpid(), 'overlap': overlap}) + '\n')
        args = sys.argv[1:]
        mode = '--resume' if '--resume' in args else '--session-id'
        sid = args[args.index(mode) + 1]
        assert args[args.index('--model') + 1] == 'fixture-model'
        assert args[args.index('--input-format') + 1] == 'stream-json'
        assert args[args.index('--output-format') + 1] == 'stream-json'
        assert '--permission-prompts' in args and '--permission-prompt-tool' in args
        turn = 0
        prompt = None

        def emit(frame):
            print(json.dumps(frame, ensure_ascii=False), flush=True)

        def result():
            emit({'type':'result', 'session_id':sid, 'is_error':False, 'future_field':{'ok':True}})

        def assistant(text):
            emit({'type':'assistant', 'message':{'content':[{'type':'text','text':text}]}})

        for line in sys.stdin:
            frame = json.loads(line)
            if frame['type'] == 'control_request':
                subtype = frame['request']['subtype']
                if subtype == 'initialize':
                    emit({'type':'control_response','response':{'subtype':'success','request_id':'unrelated'}})
                    emit({'type':'control_response','response':{'subtype':'success','request_id':frame['request_id']}})
                elif subtype == 'interrupt':
                    if prompt == 'delayed-stop':
                        time.sleep(.4)
                    sys.exit(0)
            elif frame['type'] == 'control_response':
                response = frame['response']['response']
                assistant(response['behavior'])
                result()
            elif frame['type'] == 'user':
                turn += 1
                prompt = frame['message']['content']
                emit({'type':'system','subtype':'init','session_id':sid,'fixture_mode':mode})
                if prompt == 'malformed':
                    print('not JSON', flush=True)
                    continue
                if prompt == 'wrong-session':
                    emit({'type':'result','session_id':'11111111-1111-1111-1111-111111111111'})
                    continue
                if prompt in ('permission', 'closed-permission-input'):
                    if prompt == 'closed-permission-input':
                        os.close(0)
                    emit({'type':'control_request','request_id':'permission-1',
                          'request':{'subtype':'can_use_tool','tool_name':'Bash',
                                     'input':{'command':'echo safe'},'description':'Run fixture?'}})
                    if prompt == 'closed-permission-input':
                        time.sleep(30)
                    continue
                if prompt in ('wait', 'delayed-stop'):
                    emit({'type':'stream_event','event':{'delta':{'text':'waiting'}}})
                    continue
                partial = {'type':'stream_event','event':{'delta':{'text':'€'}}}
                raw = (json.dumps(partial, ensure_ascii=False) + '\n').encode()
                split = raw.index('€'.encode()) + 1
                sys.stdout.buffer.write(raw[:split]); sys.stdout.buffer.flush(); time.sleep(.01)
                sys.stdout.buffer.write(raw[split:]); sys.stdout.buffer.flush()
                assistant(f'{os.getpid()}:{turn}:{mode}:{os.environ["FIXTURE_VALUE"]}:{prompt}')
                result()
        if prompt == 'ignore-eof':
            time.sleep(30)
        """#
}

@Suite(.timeLimit(.minutes(1)))
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
