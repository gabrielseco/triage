import Foundation
import Testing

@testable import TriageCore

@Suite(.timeLimit(.minutes(1)))
struct WorkbenchTests {
    @Test func catalogRestartRecoversBusyThreadsWithoutLosingIdentityOrConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = WorkbenchProject(name: "Project", path: "/some/project")
        let states: [WorkbenchState] = [.queued, .starting, .running, .waitingPermission, .idle, .failed, .interrupted]
        let threads = states.map { state in
            WorkbenchThread(
                projectID: project.id, title: "Thread", worktree: "/some/worktree", branch: "workbench-fixture",
                state: state, hasSession: true, messages: [.init(kind: .assistant, text: "Saved answer")],
                model: "saved-model")
        }
        let catalog = WorkbenchCatalog(projects: [project], threads: threads)
        let storage = WorkbenchStorage(directory: directory)
        #expect(try await storage.load() == WorkbenchCatalog())
        try await storage.save(catalog)
        let restarted = WorkbenchStorage(directory: directory)
        let recovered = try await restarted.load()
        #expect(recovered == catalog.recovered())
        for (original, restored) in zip(threads, recovered.threads) {
            #expect(restored.id == original.id)
            #expect(restored.sessionID == original.sessionID)
            #expect(restored.worktree == original.worktree)
            #expect(restored.hasSession)
            #expect(restored.messages == original.messages)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("catalog.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func corruptedCatalogFailsWithoutReplacingSavedDataAndRawLogsAreBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{incomplete".utf8)
        let catalog = directory.appendingPathComponent("catalog.json")
        try corrupt.write(to: catalog)
        let storage = WorkbenchStorage(directory: directory)
        await #expect(throws: DecodingError.self) { _ = try await storage.load() }
        #expect(try Data(contentsOf: catalog) == corrupt)
        let id = UUID()
        #expect(try WorkbenchStorage.raw(at: directory, id: id).isEmpty)
        try (Data(repeating: 65, count: 300_000) + Data("last frame\n".utf8))
            .write(to: directory.appendingPathComponent(id.uuidString + ".jsonl"))
        let raw = try WorkbenchStorage.raw(at: directory, id: id)
        #expect(raw.utf8.count == 256_000)
        #expect(raw.hasSuffix("last frame\n"))
    }

    @Test func createsIsolatedWorktreeFromCommittedBasePreservingInstructionsAndRelativeSymlinks() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("repo with spaces $(touch INJECTED)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("instructions"), withIntermediateDirectories: true)
        try Data("committed\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data(".claude/worktrees/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("Keep project instructions\n".utf8).write(to: root.appendingPathComponent("instructions/rules.md"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("AGENTS.md").path, withDestinationPath: "instructions/rules.md")
        _ = try await git(root, ["init", "-b", "main"])
        _ = try await git(root, ["add", "."])
        _ = try await git(
            root,
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture base"])
        _ = try await git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        try Data("dirty root\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        let project = try await WorkbenchWorktree.project(at: root.appendingPathComponent("instructions"))
        let thread = try await WorkbenchWorktree.create(project: project, title: "Isolated", model: "fixture")
        let worktree = URL(fileURLWithPath: thread.worktree)
        #expect(thread.projectID == project.id)
        #expect(thread.model == "fixture")
        #expect(thread.worktree.contains(".claude/worktrees/"))
        #expect(thread.worktree != project.path)
        #expect(
            try String(contentsOf: worktree.appendingPathComponent("tracked.txt"), encoding: .utf8) == "committed\n")
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("untracked.txt").path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent("AGENTS.md").path)
                == "instructions/rules.md")
        #expect(
            try String(contentsOf: worktree.appendingPathComponent("AGENTS.md"), encoding: .utf8)
                == "Keep project instructions\n")
        #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "dirty root\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTED").path))
        #expect(try await git(worktree, ["branch", "--show-current"]) == thread.branch)
        #expect(try await git(worktree, ["rev-parse", "HEAD"]) == git(root, ["rev-parse", "origin/main"]))
    }

    @Test func protocolSerializersCorrelateRequestsAndPreserveUntrustedTextAndInputs() throws {
        let prompt = "quoted \"hello\"\n$(touch should-never-run) €"
        let user = try decode(ClaudeStream.user(prompt))
        #expect(user["message"]["content"].text == prompt)
        #expect(user["message"]["role"].text == "user")
        #expect(user["parent_tool_use_id"] == .null)
        let initialize = try decode(ClaudeStream.control("initialize", id: "init-id"))
        #expect(initialize["request_id"].text == "init-id")
        #expect(initialize["request"]["subtype"].text == "initialize")
        #expect(initialize["request"]["hooks"] == .null)
        let input: StreamJSON = .object([
            "command": .string(prompt), "unknown": .array([.bool(true), .number(3), .null]),
        ])
        let permission = WorkbenchPermission(id: "request-id", tool: "Bash", input: input, description: "Fixture")
        let allowed = try decode(ClaudeStream.answer(permission, allow: true))
        #expect(allowed["response"]["request_id"].text == permission.id)
        #expect(allowed["response"]["response"]["behavior"].text == "allow")
        #expect(allowed["response"]["response"]["updatedInput"] == input)
        let denied = try decode(ClaudeStream.answer(permission, allow: false))
        #expect(denied["response"]["response"]["behavior"].text == "deny")
        let unsupported = try decode(ClaudeStream.unsupported(id: "unknown-request"))
        #expect(unsupported["response"]["request_id"].text == "unknown-request")
        #expect(unsupported["response"]["subtype"].text == "error")
        #expect(try JSONDecoder().decode(StreamJSON.self, from: JSONEncoder().encode(input)) == input)
    }

    @Test func lineBufferPreservesSplitUTF8RejectsMalformedTailAndLimitsFrames() throws {
        var buffer = JSONLineBuffer()
        let bytes = Data(#"{"type":"future","text":"€","unknown":{"number":3}}"#.utf8)
        let euro = try #require(bytes.range(of: Data("€".utf8)))
        #expect(try buffer.append(Data(bytes[..<(euro.lowerBound + 1)])).isEmpty)
        let lines = try buffer.append(Data(bytes[(euro.lowerBound + 1)...]) + Data("\n\n".utf8))
        #expect(lines == [bytes])
        let frame = try JSONDecoder().decode(StreamJSON.self, from: try #require(lines.first))
        #expect(frame["type"].text == "future")
        #expect(frame["text"].text == "€")
        #expect(frame["unknown"]["number"] == .number(3))
        try buffer.finish()
        #expect(try buffer.append(Data("{\"truncated\":".utf8)).isEmpty)
        #expect(throws: WorkbenchError.self) { try buffer.finish() }
        var malformed = JSONLineBuffer()
        let malformedLines = try malformed.append(Data("not json\n".utf8))
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(StreamJSON.self, from: malformedLines[0]) }
        var oversized = JSONLineBuffer()
        #expect(throws: WorkbenchError.self) {
            _ = try oversized.append(Data(repeating: 65, count: 8 * 1024 * 1024 + 1))
        }
    }

    private func decode(_ data: Data) throws -> StreamJSON {
        #expect(data.last == 10)
        return try JSONDecoder().decode(StreamJSON.self, from: data)
    }

    private func git(_ directory: URL, _ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run("/usr/bin/git", ["-C", directory.path] + arguments)
        guard result.status == 0 else { throw WorkbenchError(result.stderr) }
        return result.trimmedStdout
    }
}
