import Darwin
import Foundation

@testable import TriageCore

actor ThreadUpdates {
    private var values: [WorkbenchUpdate] = []
    func append(_ update: WorkbenchUpdate) { values.append(update) }
    func snapshot() -> [WorkbenchUpdate] { values }

    func wait(_ predicate: @Sendable ([WorkbenchUpdate]) -> Bool) async throws -> [WorkbenchUpdate] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate(values) { return values }
            try await Task.sleep(for: .milliseconds(10))
        }
        let diagnostics = values.compactMap { update -> String? in
            if case .message(_, let message) = update, message.kind == .error { return message.text }
            return nil
        }.joined(separator: "\n")
        throw WorkbenchError("Timed out waiting for scripted thread updates: \(diagnostics)")
    }
}

func stateCount(_ values: [WorkbenchUpdate], _ id: UUID, _ state: WorkbenchState) -> Int {
    values.filter { if case .state(let thread, let value) = $0 { thread == id && value == state } else { false } }.count
}

func assistantTexts(_ values: [WorkbenchUpdate], _ id: UUID) -> [String] {
    values.compactMap {
        if case .message(let thread, let message) = $0, thread == id, message.kind == .assistant {
            message.text
        } else {
            nil
        }
    }
}

struct SupervisorFixture {
    let directory: URL
    let supervisor: ThreadSupervisor
    let updates: ThreadUpdates
    let observer: Task<Void, Never>

    init(limit: Int = 2) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("scripted backend.py")
        try Data(Self.script.utf8).write(to: script)
        var environment = ProcessInfo.processInfo.environment
        environment["FIXTURE_VALUE"] = "forwarded"
        environment["PYTHONUTF8"] = "1"
        supervisor = ThreadSupervisor(
            limit: limit, executable: "/usr/bin/python3", prefix: [script.path],
            environment: environment, logDirectory: directory.appendingPathComponent("logs"))
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
        assert not any('skip-permissions' in a or a == '--permission-mode' for a in args)
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
                if prompt in ('policy-allowed', 'policy-prompted', 'policy-guardrail'):
                    command = {'policy-allowed': 'git status', 'policy-prompted': 'swift test',
                               'policy-guardrail': 'rm -rf build'}[prompt]
                    emit({'type':'control_request','request_id':'policy-1',
                          'request':{'subtype':'can_use_tool','tool_name':'Bash',
                                     'input':{'command':command},'description':'Run fixture?'}})
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
