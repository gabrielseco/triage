import Foundation

public enum WorkbenchUpdate: Sendable {
    case state(UUID, WorkbenchState)
    case message(UUID, WorkbenchMessage)
    case partial(UUID, String)
    case permission(UUID, WorkbenchPermission)
    case cancelPermission(UUID, String)
    case raw(UUID, String)
    case session(UUID)
}

public actor ThreadSupervisor {
    public nonisolated let events: AsyncStream<WorkbenchUpdate>
    private let output: AsyncStream<WorkbenchUpdate>.Continuation
    private let limit: Int
    private let executable: String
    private let prefix: [String]
    private let environment: [String: String]
    private let logDirectory: URL
    private var queue: [(WorkbenchThread, String)] = []
    private var live: [UUID: Run] = [:]
    private var policies: [UUID: PermissionPolicy] = [:]
    private var shuttingDown = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    private struct Run {
        let token: UUID
        let thread: WorkbenchThread
        var session: Subprocess.Session?
        var buffer = JSONLineBuffer()
        var ready = false
        var busy = true
        var terminating = false
        let initialization: String
        let prompt: String
        var permissions: [String: WorkbenchPermission] = [:]
    }

    public init(
        limit: Int = 2, executable: String = "/usr/bin/env", prefix: [String] = ["claude"],
        environment: [String: String] = ProcessInfo.processInfo.environment, logDirectory: URL
    ) {
        let pair = AsyncStream<WorkbenchUpdate>.makeStream()
        events = pair.stream
        output = pair.continuation
        self.limit = max(1, limit)
        self.executable = executable
        self.prefix = prefix
        self.environment = environment
        self.logDirectory = logDirectory
    }

    /// Replaces what runs without asking for a thread, effective for the next tool request.
    public func setPolicy(_ policy: PermissionPolicy, for id: UUID) {
        guard live[id] != nil || queue.contains(where: { $0.0.id == id }) else { return }
        policies[id] = policy
    }

    public func submit(
        _ thread: WorkbenchThread, prompt: String, policy: PermissionPolicy = PermissionPolicy()
    ) async throws {
        guard !shuttingDown else { throw WorkbenchError("The thread engine is shutting down.") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !queue.contains(where: { $0.0.id == thread.id }) else { throw WorkbenchError("This thread is queued.") }
        policies[thread.id] = policy
        if var run = live[thread.id], !run.terminating {
            guard !run.busy, let session = run.session else { throw WorkbenchError("This thread is already running.") }
            run.busy = true
            live[thread.id] = run
            output.yield(.state(thread.id, .running))
            do { try await session.send(ClaudeStream.user(prompt)) } catch {
                fail(thread.id, token: run.token, error: error)
            }
        } else {
            queue.append((thread, prompt))
            output.yield(.state(thread.id, .queued))
            pump()
        }
    }

    public func answer(_ permission: WorkbenchPermission, threadID: UUID, allow: Bool) async throws {
        guard var run = live[threadID], !run.terminating,
            run.permissions[permission.id] == permission, let session = run.session
        else {
            throw WorkbenchError("This permission request is no longer active.")
        }
        run.permissions.removeValue(forKey: permission.id)
        live[threadID] = run
        do { try await session.send(ClaudeStream.answer(permission, allow: allow)) } catch {
            fail(threadID, token: run.token, error: error)
            throw error
        }
        guard let current = live[threadID], current.token == run.token, !current.terminating else { return }
        output.yield(.cancelPermission(threadID, permission.id))
        if current.busy {
            output.yield(.state(threadID, current.permissions.isEmpty ? .running : .waitingPermission))
        }
    }

    public func stop(_ id: UUID) async {
        queue.removeAll { $0.0.id == id }
        if let run = live[id], !run.terminating {
            retire(id, token: run.token, interrupt: true)
        }
        output.yield(.state(id, .interrupted))
        pump()
    }

    public func shutdown() async {
        shuttingDown = true
        for (thread, _) in queue { output.yield(.state(thread.id, .interrupted)) }
        queue.removeAll()
        for (id, run) in live {
            live[id]?.terminating = true
            run.session?.terminate()
            if run.busy { output.yield(.state(id, .interrupted)) }
        }
        if !live.isEmpty {
            await withCheckedContinuation { shutdownWaiters.append($0) }
        }
    }

    private func pump() {
        guard !shuttingDown else { return }
        while !queue.isEmpty {
            if live.count >= limit {
                if let idle = live.first(where: { !$0.value.busy && !$0.value.terminating }) {
                    retire(idle.key, token: idle.value.token)
                }
                return
            }
            guard live[queue[0].0.id] == nil else { return }
            let (thread, prompt) = queue.removeFirst()
            let token = UUID()
            let initialization = UUID().uuidString
            live[thread.id] = Run(token: token, thread: thread, initialization: initialization, prompt: prompt)
            output.yield(.state(thread.id, .starting))
            Task { await launch(thread, token: token) }
        }
    }

    private func launch(_ thread: WorkbenchThread, token: UUID) async {
        guard let run = live[thread.id], run.token == token else { return }
        if run.terminating {
            release(thread.id)
            pump()
            return
        }
        do {
            var arguments =
                prefix + [
                    "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--replay-user-messages", "--permission-prompts", "host",
                    "--permission-prompt-tool", "stdio",
                    "--append-system-prompt",
                    "Read and follow this project's AGENTS.md if present, alongside CLAUDE.md and project skills. "
                        + "Work in the current isolated Git worktree. "
                        + "Follow the project's verification and review workflow.",
                    thread.hasSession ? "--resume" : "--session-id", thread.sessionID.uuidString.lowercased(),
                ]
            if let model = thread.model { arguments += ["--model", model] }
            let session = try await Subprocess.start(
                executable, arguments, directory: URL(fileURLWithPath: thread.worktree), environment: environment)
            guard live[thread.id]?.token == token else { session.terminate(); return }
            live[thread.id]?.session = session
            if live[thread.id]?.terminating == true {
                session.terminate()
            } else {
                do {
                    try await session.send(ClaudeStream.control("initialize", id: run.initialization))
                    Task {
                        try? await Task.sleep(for: .seconds(30))
                        self.initializationTimeout(thread.id, token: token)
                    }
                } catch { fail(thread.id, token: token, error: error) }
            }
            for await event in session.events { await consume(event, id: thread.id, token: token) }
        } catch {
            fail(thread.id, token: token, error: error)
            if live[thread.id]?.token == token { release(thread.id) }
            pump()
        }
    }

    private func initializationTimeout(_ id: UUID, token: UUID) {
        guard let run = live[id], run.token == token, !run.ready, !run.terminating else { return }
        fail(id, token: token, error: WorkbenchError("Claude did not initialize within 30 seconds."))
    }

    private func consume(_ event: Subprocess.Event, id: UUID, token: UUID) async {
        guard var run = live[id], run.token == token else { return }
        if case .exited(let status) = event {
            exited(id, run: run, status: status)
            return
        }
        guard !run.terminating else { return }
        do {
            switch event {
            case .stdout(let data):
                let lines = try run.buffer.append(data)
                live[id] = run
                for line in lines {
                    try appendLog(line, id: id)
                    output.yield(.raw(id, String(decoding: line, as: UTF8.self) + "\n"))
                    let frame = try JSONDecoder().decode(StreamJSON.self, from: line)
                    try await handle(frame, id: id, token: token)
                }
            case .stderr(let data):
                let text = String(decoding: data, as: UTF8.self)
                output.yield(.raw(id, text))
                output.yield(.message(id, .init(kind: .error, text: String(text.prefix(4000)))))
            case .exited: break
            }
        } catch { fail(id, token: token, error: error) }
    }

}

extension ThreadSupervisor {
    private func exited(_ id: UUID, run: Run, status: Int32) {
        release(id)
        if !run.terminating {
            do {
                try run.buffer.finish()
                if run.busy || status != 0 {
                    throw WorkbenchError("Claude exited with status \(status).")
                }
            } catch {
                output.yield(.state(id, .failed))
                output.yield(.message(id, .init(kind: .error, text: error.localizedDescription)))
            }
        }
        pump()
    }

    private func release(_ id: UUID) {
        live.removeValue(forKey: id)
        policies.removeValue(forKey: id)
        if live.isEmpty {
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func retire(_ id: UUID, token: UUID, interrupt: Bool = false) {
        guard let run = live[id], run.token == token, !run.terminating else { return }
        live[id]?.terminating = true
        guard let session = run.session else { return }
        // The slot remains reserved until .exited, including while stdin or startup is blocked.
        Task {
            try? await Task.sleep(for: .seconds(2))
            session.terminate()
        }
        if interrupt {
            Task {
                try? await session.send(ClaudeStream.control("interrupt", id: UUID().uuidString))
                session.finishInput()
            }
        } else {
            session.finishInput()
        }
    }

    private func handle(_ frame: StreamJSON, id: UUID, token: UUID) async throws {
        guard let run = live[id], run.token == token, !run.terminating, let session = run.session else { return }
        guard case .object = frame else { throw WorkbenchError("CLI output is not a JSON object.") }
        guard frame["parent_tool_use_id"].text == nil else { return }
        try await dispatch(frame, id: id, run: run, session: session)
    }

    private func dispatch(_ frame: StreamJSON, id: UUID, run: Run, session: Subprocess.Session) async throws {
        switch frame["type"].text {
        case "control_response": try await initialized(frame, id: id, run: run, session: session)
        case "control_request": try await permission(frame, id: id, session: session)
        case "control_cancel_request": cancelPermission(frame, id: id)
        case "system": try sessionInitialized(frame, id: id, thread: run.thread)
        case "stream_event": output.yield(.partial(id, frame["event"]["delta"]["text"].text ?? ""))
        case "assistant": assistant(frame, id: id)
        case "result":
            try validateSession(frame, thread: run.thread)
            complete(frame, id: id)
        default: break
        }
    }

    private func initialized(_ frame: StreamJSON, id: UUID, run: Run, session: Subprocess.Session) async throws {
        if frame["response"]["request_id"].text == run.initialization, !run.ready {
            guard frame["response"]["subtype"].text == "success" else {
                throw WorkbenchError(frame["response"]["error"].text ?? "Claude initialization failed.")
            }
            live[id]?.ready = true
            output.yield(.state(id, .running))
            try await session.send(ClaudeStream.user(run.prompt))
        }
    }

    private func cancelPermission(_ frame: StreamJSON, id: UUID) {
        if let request = frame["request_id"].text {
            live[id]?.permissions.removeValue(forKey: request)
            output.yield(.cancelPermission(id, request))
            if live[id]?.permissions.isEmpty == true { output.yield(.state(id, .running)) }
        }
    }

    private func sessionInitialized(_ frame: StreamJSON, id: UUID, thread: WorkbenchThread) throws {
        if frame["subtype"].text == "init" {
            try validateSession(frame, thread: thread)
            output.yield(.session(id))
        }
    }

    private func permission(_ frame: StreamJSON, id: UUID, session: Subprocess.Session) async throws {
        guard let request = frame["request_id"].text else { throw WorkbenchError("Permission request has no ID.") }
        guard frame["request"]["subtype"].text == "can_use_tool",
            let tool = frame["request"]["tool_name"].text
        else { try await session.send(ClaudeStream.unsupported(id: request)); return }
        let permission = WorkbenchPermission(
            id: request, tool: tool, input: frame["request"]["input"],
            description: frame["request"]["description"].text ?? "Allow this tool call?")
        if case .allow(let reason) = (policies[id] ?? PermissionPolicy()).decide(tool: tool, input: permission.input) {
            try await session.send(ClaudeStream.answer(permission, allow: true))
            let summary = PermissionPolicy.summary(tool: tool, input: permission.input)
            output.yield(.message(id, .init(kind: .step, text: "Auto-allowed: \(summary) (\(reason))")))
            return
        }
        live[id]?.permissions[request] = permission
        output.yield(.permission(id, permission))
        output.yield(.state(id, .waitingPermission))
    }

    private func assistant(_ frame: StreamJSON, id: UUID) {
        for block in frame["message"]["content"].values {
            if block["type"].text == "text", let text = block["text"].text {
                output.yield(.message(id, .init(kind: .assistant, text: String(text.prefix(32_000)))))
            } else if block["type"].text == "tool_use", let name = block["name"].text {
                output.yield(.message(id, .init(kind: .step, text: "Using \(name)")))
            }
        }
    }

    private func complete(_ frame: StreamJSON, id: UUID) {
        live[id]?.busy = false
        live[id]?.permissions.removeAll()
        output.yield(.session(id))
        if frame["is_error"].flag {
            let error = frame["result"].text ?? frame["errors"].values.compactMap(\.text).joined(separator: "\n")
            output.yield(
                .message(id, .init(kind: .error, text: error.isEmpty ? "Claude could not finish this turn." : error)))
            output.yield(.state(id, .failed))
        } else {
            output.yield(.state(id, .idle))
        }
        pump()
    }

    private func validateSession(_ frame: StreamJSON, thread: WorkbenchThread) throws {
        guard let id = frame["session_id"].text, UUID(uuidString: id) == thread.sessionID else {
            throw WorkbenchError("Claude returned an unexpected session ID.")
        }
    }

    private func fail(_ id: UUID, token: UUID, error: any Error) {
        guard let run = live[id], run.token == token, !run.terminating else { return }
        live[id]?.terminating = true
        run.session?.terminate()
        output.yield(.state(id, .failed))
        output.yield(.message(id, .init(kind: .error, text: error.localizedDescription)))
        pump()
    }

    private func appendLog(_ line: Data, id: UUID) throws {
        try FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = logDirectory.appendingPathComponent(id.uuidString + ".jsonl")
        if !FileManager.default.fileExists(atPath: path.path) {
            guard
                FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw WorkbenchError("Could not create the thread log.")
            }
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data([10]))
    }
}
