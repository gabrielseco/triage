import Foundation
import Testing

@testable import TriageCore

private var reviewScripts: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts")
}

private func reviewCommand(_ repo: URL, _ arguments: [String]) async throws -> String {
    let output = try await Subprocess.run(
        "/bin/sh", ["-c", "cd \"$1\" && shift && exec \"$@\"", "review-test", repo.path] + arguments)
    try #require(output.status == 0, "\(output.stderr)")
    return output.trimmedStdout
}

private func reviewFixture(_ scratch: URL) async throws -> URL {
    let repo = scratch.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try await reviewCommand(repo, ["git", "init", "-b", "feature"])
    _ = try await reviewCommand(repo, ["git", "config", "user.name", "Review Test"])
    _ = try await reviewCommand(repo, ["git", "config", "user.email", "review@example.com"])
    try Data(".claude/tasks/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    _ = try await reviewCommand(repo, ["git", "add", "."])
    _ = try await reviewCommand(repo, ["git", "commit", "-m", "fixture"])
    let base = try await reviewCommand(repo, ["git", "rev-parse", "HEAD"])
    let spec = scratch.appendingPathComponent("goal-input.json")
    let input = #"{"request":"Review fixture","criteria":[{"text":"Recorded","proof":"Test"}],"outOfScope":[]}"#
    try Data(input.utf8).write(to: spec)
    _ = try await reviewCommand(
        repo,
        [
            "python3", reviewScripts.appendingPathComponent("task-goal.py").path,
            "init", "review-task", "--input", spec.path, "--base", base,
        ])
    _ = try await reviewCommand(
        repo, ["python3", reviewScripts.appendingPathComponent("task-goal.py").path, "approve", "review-task"])
    return repo
}

@Test func reviewProducerPublishesTypedMetadataAndCleanResults() async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let repo = try await reviewFixture(scratch)
    let head = try await reviewCommand(repo, ["git", "rev-parse", "HEAD"])
    let task = repo.appendingPathComponent(".claude/tasks/review-task")
    for source in ["pr-review", "design-review"] {
        _ = try await reviewCommand(
            repo,
            [
                "python3", reviewScripts.appendingPathComponent("task-review.py").path,
                "snapshot", "review-task", source, "--base", head, "--head", head,
            ])
        let contextData = try Data(contentsOf: task.appendingPathComponent("review-inputs/\(source).json"))
        let provenance = try JSONDecoder().decode(TaskReview.Provenance.self, from: contextData)
        let findings: [TaskReview.Finding] =
            source == "pr-review"
            ? [
                .init(
                    severity: .warning, message: "Fixture finding", file: "Example.swift", line: 2,
                    evidence: ["Observed fixture test result"])
            ] : []
        let result = TaskReview(
            taskID: "review-task", source: source, findings: findings,
            status: .complete, provenance: provenance)
        let input = scratch.appendingPathComponent("review-result.json")
        try JSONEncoder().encode(result).write(to: input)
        _ = try await reviewCommand(
            repo,
            [
                "python3", reviewScripts.appendingPathComponent("task-review.py").path,
                "record", "review-task", source, "--input", input.path,
            ])
        let published = try Data(contentsOf: task.appendingPathComponent("reviews/\(source).json"))
        #expect(try TaskArtifactReader.decodeReview(published, expectedTaskID: "review-task") == result)
        #expect(provenance.headCommit == head)
    }
}

@Test func reviewReaderRejectsInconsistentProvenance() throws {
    for (taskID, source) in [("other-task", "pr-review"), ("review-task", "other-source")] {
        let context = TaskReview.Provenance(
            taskID: taskID, source: source, branch: "feature", baseCommit: "base", tree: "tree",
            goalSHA256: "goal", goalManifestSHA256: "manifest")
        let result = TaskReview(
            taskID: "review-task", source: "pr-review", findings: [],
            status: .complete, provenance: context)
        let error: TaskArtifactError =
            taskID == "other-task"
            ? .taskMismatch(expected: "review-task", actual: taskID)
            : .reviewSourceMismatch(expected: "pr-review", actual: source)
        let data = try JSONEncoder().encode(result)
        #expect(throws: error) { try TaskArtifactReader.decodeReview(data, expectedTaskID: "review-task") }
    }
}

@Test func reviewReaderRejectsIncompleteStatusAndFutureProvenance() {
    let prefix = #"{"schemaVersion":1,"taskID":"review-task","source":"pr-review","findings":[],"#
    #expect(throws: DecodingError.self) {
        try TaskArtifactReader.decodeReview(
            Data((prefix + #""status":"incomplete"}"#).utf8),
            expectedTaskID: "review-task")
    }
    let context =
        #"""
        "provenance":{"schemaVersion":2,"taskID":"review-task","source":"pr-review",
        "branch":"feature","baseCommit":"base","tree":"tree","goalSHA256":"goal",
        "goalManifestSHA256":"manifest"}}
        """#
    #expect(throws: TaskArtifactError.unsupportedVersion(2)) {
        try TaskArtifactReader.decodeReview(Data((prefix + context).utf8), expectedTaskID: "review-task")
    }
}
