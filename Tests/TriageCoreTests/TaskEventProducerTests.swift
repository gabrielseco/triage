import Foundation
import Testing

@testable import TriageCore

private var eventScripts: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts")
}

private func eventCommand(_ repo: URL, _ arguments: [String]) async throws -> String {
    let output = try await Subprocess.run(
        "/bin/sh", ["-c", "cd \"$1\" && shift && exec \"$@\"", "event-test", repo.path] + arguments)
    try #require(output.status == 0, "\(output.stderr)")
    return output.trimmedStdout
}

private func eventFixture(_ repo: URL) async throws -> String {
    _ = try await eventCommand(repo, ["git", "init", "-b", "feature"])
    _ = try await eventCommand(repo, ["git", "config", "user.name", "Event Test"])
    _ = try await eventCommand(repo, ["git", "config", "user.email", "event@example.com"])
    _ = try await eventCommand(repo, ["git", "remote", "add", "origin", "https://github.com/fixture/project.git"])
    try Data(".claude/tasks/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("code.txt"))
    _ = try await eventCommand(repo, ["git", "add", "."])
    _ = try await eventCommand(repo, ["git", "commit", "-m", "fixture"])
    let head = try await eventCommand(repo, ["git", "rev-parse", "HEAD"])
    let spec = repo.appendingPathComponent("goal-input.json")
    let goal = #"{"request":"Lifecycle fixture","criteria":[{"text":"Recorded","proof":"Test"}],"outOfScope":[]}"#
    try Data(goal.utf8).write(to: spec)
    _ = try await eventCommand(
        repo,
        [
            "python3", eventScripts.appendingPathComponent("task-goal.py").path,
            "init", "lifecycle-task", "--input", spec.path, "--base", head,
        ])
    _ = try await eventCommand(
        repo, ["python3", eventScripts.appendingPathComponent("task-goal.py").path, "approve", "lifecycle-task"])
    return head
}

private func eventResponses(_ repo: URL, head: String) throws -> URL {
    let repository = ["full_name": "fixture/project"]
    let pr: [String: Any] = [
        "number": 7, "html_url": "https://github.com/fixture/project/pull/7",
        "created_at": "2026-10-12T10:00:00Z", "merged_at": "2026-10-12T11:00:00Z",
        "merge_commit_sha": String(repeating: "a", count: 40),
        "head": ["sha": head, "ref": "feature", "repo": repository],
        "base": ["sha": head, "repo": repository],
    ]
    let run: [String: Any] = [
        "id": 19, "run_attempt": 1, "repository": repository,
        "head_sha": head, "head_branch": "feature", "pull_requests": [["number": 7]],
        "status": "completed", "conclusion": "failure", "event": "pull_request", "name": "CI",
        "html_url": "https://github.com/fixture/project/actions/runs/19",
        "updated_at": "2026-10-12T10:30:00Z",
    ]
    let fixture: [String: Any] = ["repo": ["nameWithOwner": "fixture/project"], "pr": pr, "run": run]
    try JSONSerialization.data(withJSONObject: fixture).write(to: repo.appendingPathComponent("responses.json"))
    let bin = repo.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let stub = """
        #!/usr/bin/env python3
        import json, sys
        from pathlib import Path
        responses = json.loads(Path('responses.json').read_text())
        key = 'repo' if sys.argv[1] == 'repo' else ('run' if '/actions/runs/' in sys.argv[2] else 'pr')
        print(json.dumps(responses[key]))
        """
    let gh = bin.appendingPathComponent("gh")
    try Data(stub.utf8).write(to: gh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    return bin
}

@Test func eventProducerPublishesReadableLifecycleHistory() async throws {
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    let head = try await eventFixture(repo)
    let bin = try eventResponses(repo, head: head)
    let path = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    let log = repo.appendingPathComponent(".claude/tasks/lifecycle-task/events.jsonl")
    for command in ["pr-created", "ci-completed", "pr-merged"] {
        let arguments =
            ["env", "PATH=\(path)", "python3", eventScripts.appendingPathComponent("task-event.py").path]
            + [command, "lifecycle-task", "--pr", "7", "--head", head]
            + (command == "ci-completed" ? ["--run", "19"] : [])
        _ = try await eventCommand(repo, arguments)
        let first = try Data(contentsOf: log)
        _ = try await eventCommand(repo, arguments)
        #expect(try Data(contentsOf: log) == first)
    }
    let decoded = try TaskArtifactReader.readEvents(at: log, expectedTaskID: "lifecycle-task")
    let events = try #require(decoded)
    #expect(events.map(\.kind) == ["pr.created", "ci.completed", "pr.merged"])
    #expect(Set(events.map(\.id)).count == 3)
    #expect(events.allSatisfy { $0.payload["headCommit"] == head && $0.payload["repo"] == "fixture/project" })
    #expect(events[1].payload["status"] == "failure")
    #expect(events[1].payload["runAttempt"] == "1")
    #expect(events[2].payload["mergeCommit"] == String(repeating: "a", count: 40))
}
