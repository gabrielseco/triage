import Foundation
import Testing

@testable import TriageCore

private let artifactTaskID = "workbench-artifacts"

private func artifactData(_ body: String, taskID: String = artifactTaskID, version: Int = 1) -> Data {
    let encodedID = String(decoding: (try? JSONEncoder().encode(taskID)) ?? Data(), as: UTF8.self)
    return Data("{\"schemaVersion\":\(version),\"taskID\":\(encodedID),\(body)}".utf8)
}

@Test func artifactVerdictPreservesCriteriaAndAllowsUnknownFields() throws {
    let data = artifactData(
        #"""
        "verdict":"fail","criteria":[{"text":"Empty state","pass":false,"evidence":["shots/empty.png"]}],
        "futureField":{"enabled":true}
        """#)
    let verdict = try TaskArtifactReader.decodeVerdict(data, expectedTaskID: artifactTaskID)
    #expect(verdict.schemaVersion == 1)
    #expect(verdict.verdict == .fail)
    #expect(verdict.criteria == [.init(text: "Empty state", pass: false, evidence: ["shots/empty.png"])])
}

@Test func artifactRejectsFutureVersionBeforeReadingItsBody() {
    #expect(throws: TaskArtifactError.unsupportedVersion(2)) {
        try TaskArtifactReader.decodeVerdict(artifactData("\"newBody\":[]", version: 2), expectedTaskID: artifactTaskID)
    }
}

@Test func artifactRejectsTaskMismatch() {
    #expect(throws: TaskArtifactError.taskMismatch(expected: artifactTaskID, actual: "other-task")) {
        try TaskArtifactReader.decodeReview(
            artifactData("\"source\":\"pr-review\",\"findings\":[]", taskID: "other-task"),
            expectedTaskID: artifactTaskID)
    }
}

@Test(arguments: ["", "../escape", "Uppercase", "space id", "trailing-", "double--dash", "under_score", "trailing\n"])
func artifactRejectsInvalidTaskID(taskID: String) {
    #expect(throws: TaskArtifactError.invalidTaskID(taskID)) {
        try TaskArtifactReader.decodeVerdict(
            artifactData("\"verdict\":\"pass\",\"criteria\":[]", taskID: taskID), expectedTaskID: taskID)
    }
}

@Test func artifactRejectsInvalidExpectedTaskID() {
    #expect(throws: TaskArtifactError.invalidTaskID("../outside")) {
        try TaskArtifactReader.decodeVerdict(
            artifactData("\"verdict\":\"pass\",\"criteria\":[]"),
            expectedTaskID: "../outside")
    }
}

@Test func artifactScreenshotsPreserveOptionalMetadata() throws {
    let manifest = TaskScreenshotManifest(
        taskID: artifactTaskID,
        screenshots: [
            .init(path: "shots/light.png", caption: "Inbox", appearance: .light, criterion: "Readable rows"),
            .init(path: "shots/nested/dark.png", caption: "Settings", appearance: .dark),
            .init(path: "shots/empty.png", caption: "Empty state"),
        ])
    let decoded = try TaskArtifactReader.decodeScreenshots(
        JSONEncoder().encode(manifest), expectedTaskID: artifactTaskID)
    #expect(decoded == manifest)
}

@Test(arguments: [
    "/shots/screen.png", "../shots/screen.png", "shots/../screen.png", "shots/./screen.png", "shots//screen.png",
    "shots/", "shots", "other/screen.png", "shots\\screen.png", "shots/%2e%2e/screen.png", "shots/null\0.png",
])
func artifactRejectsUnsafeScreenshotPaths(path: String) throws {
    let manifest = TaskScreenshotManifest(taskID: artifactTaskID, screenshots: [.init(path: path, caption: "Shot")])
    let data = try JSONEncoder().encode(manifest)
    #expect(throws: TaskArtifactError.unsafeScreenshotPath(path)) {
        try TaskArtifactReader.decodeScreenshots(data, expectedTaskID: artifactTaskID)
    }
}

@Test func artifactReviewPreservesSeverityAndLocation() throws {
    let review = TaskReview(
        taskID: artifactTaskID, source: "pr-review",
        findings: [
            .init(severity: .blocking, message: "Blocking I/O", file: "Sources/Triage/App.swift", line: 12),
            .init(severity: .warning, message: "Long text"),
            .init(severity: .suggestion, message: "Simplify"),
        ])
    #expect(try TaskArtifactReader.decodeReview(JSONEncoder().encode(review), expectedTaskID: artifactTaskID) == review)
    let empty = TaskReview(taskID: artifactTaskID, source: "design-review", findings: [])
    #expect(try TaskArtifactReader.decodeReview(JSONEncoder().encode(empty), expectedTaskID: artifactTaskID) == empty)
}

@Test func artifactEventsPreserveOrderAndUnknownKinds() throws {
    let events = [
        TaskEvent(taskID: artifactTaskID, id: UUID(), timestamp: "2026-10-12T10:00:00Z", kind: "started", payload: [:]),
        TaskEvent(
            taskID: artifactTaskID, id: UUID(), timestamp: "2026-10-12T10:00:01.123+02:00", kind: "future-kind",
            payload: ["message": "first\nsecond"]),
    ]
    let records = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    let data = Data(("\n" + records.joined(separator: "\r\n \n") + "\n").utf8)
    #expect(try TaskArtifactReader.decodeEvents(data, expectedTaskID: artifactTaskID) == events)
    #expect(try TaskArtifactReader.decodeEvents(Data(), expectedTaskID: artifactTaskID).isEmpty)
}

@Test func artifactEventsRejectInvalidTimestampAndUTF8() throws {
    let event = TaskEvent(taskID: artifactTaskID, id: UUID(), timestamp: "yesterday", kind: "started", payload: [:])
    let data = try JSONEncoder().encode(event)
    #expect(throws: TaskArtifactError.invalidTimestamp("yesterday")) {
        try TaskArtifactReader.decodeEvents(data, expectedTaskID: artifactTaskID)
    }
    #expect(throws: TaskArtifactError.invalidUTF8) {
        try TaskArtifactReader.decodeEvents(Data([0xFF]), expectedTaskID: artifactTaskID)
    }
}

@Test func artifactEventsRejectMalformedRecordAndMismatchedTask() throws {
    let first = TaskEvent(
        taskID: artifactTaskID, id: UUID(), timestamp: "2026-10-12T10:00:00Z", kind: "started", payload: [:])
    let encoded = try JSONEncoder().encode(first)
    var malformed = encoded
    malformed.append(Data("\n{\"schemaVersion\":".utf8))
    #expect(throws: DecodingError.self) {
        try TaskArtifactReader.decodeEvents(malformed, expectedTaskID: artifactTaskID)
    }
    let second = TaskEvent(taskID: "other-task", id: UUID(), timestamp: first.timestamp, kind: "finished", payload: [:])
    var mismatched = encoded
    mismatched.append(Data("\n".utf8))
    mismatched.append(try JSONEncoder().encode(second))
    #expect(throws: TaskArtifactError.taskMismatch(expected: artifactTaskID, actual: "other-task")) {
        try TaskArtifactReader.decodeEvents(mismatched, expectedTaskID: artifactTaskID)
    }
}

@Test func artifactMalformedAndInvalidEnumsThrow() {
    #expect(throws: DecodingError.self) {
        try TaskArtifactReader.decodeVerdict(Data("{".utf8), expectedTaskID: artifactTaskID)
    }
    #expect(throws: DecodingError.self) {
        try TaskArtifactReader.decodeVerdict(
            artifactData("\"verdict\":\"maybe\",\"criteria\":[]"),
            expectedTaskID: artifactTaskID)
    }
    #expect(throws: DecodingError.self) {
        try TaskArtifactReader.decodeReview(artifactData("\"source\":\"pr-review\""), expectedTaskID: artifactTaskID)
    }
}

@Test func artifactFileReadersDistinguishMissingFromMalformed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("artifact.json")
    #expect(try TaskArtifactReader.readVerdict(at: url, expectedTaskID: artifactTaskID) == nil)
    #expect(try TaskArtifactReader.readScreenshots(at: url, expectedTaskID: artifactTaskID) == nil)
    #expect(try TaskArtifactReader.readReview(at: url, expectedTaskID: artifactTaskID) == nil)
    #expect(try TaskArtifactReader.readEvents(at: url, expectedTaskID: artifactTaskID) == nil)
    try Data("{".utf8).write(to: url)
    #expect(throws: DecodingError.self) {
        try TaskArtifactReader.readVerdict(at: url, expectedTaskID: artifactTaskID)
    }
    let verdict = TaskVerdict(taskID: artifactTaskID, verdict: .pass, criteria: [])
    try JSONEncoder().encode(verdict).write(to: url)
    #expect(try TaskArtifactReader.readVerdict(at: url, expectedTaskID: artifactTaskID) == verdict)
    let manifest = TaskScreenshotManifest(taskID: artifactTaskID, screenshots: [])
    try JSONEncoder().encode(manifest).write(to: url)
    #expect(try TaskArtifactReader.readScreenshots(at: url, expectedTaskID: artifactTaskID) == manifest)
    let review = TaskReview(taskID: artifactTaskID, source: "pr-review", findings: [])
    try JSONEncoder().encode(review).write(to: url)
    #expect(try TaskArtifactReader.readReview(at: url, expectedTaskID: artifactTaskID) == review)
    let event = TaskEvent(
        taskID: artifactTaskID, id: UUID(), timestamp: "2026-10-12T10:00:00Z", kind: "started", payload: [:])
    try JSONEncoder().encode(event).write(to: url)
    #expect(try TaskArtifactReader.readEvents(at: url, expectedTaskID: artifactTaskID) == [event])
}

private var artifactRepository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@Test func artifactDocumentedFixturesDecode() throws {
    let examples = artifactRepository.appendingPathComponent("docs/artifacts/examples")
    let verdict = try TaskArtifactReader.readVerdict(
        at: examples.appendingPathComponent("verdict.json"),
        expectedTaskID: artifactTaskID)
    #expect(verdict?.verdict == .pass)
    let shots = try TaskArtifactReader.readScreenshots(
        at: examples.appendingPathComponent("shots.json"),
        expectedTaskID: artifactTaskID)
    #expect(shots?.screenshots.first?.path == "shots/inbox-light.png")
    let review = try TaskArtifactReader.readReview(
        at: examples.appendingPathComponent("reviews/pr-review.json"),
        expectedTaskID: artifactTaskID)
    #expect(review?.source == "pr-review")
    let events = try TaskArtifactReader.readEvents(
        at: examples.appendingPathComponent("events.jsonl"),
        expectedTaskID: artifactTaskID)
    #expect(events?.first?.kind == "pr.created")
}

@Test func artifactScreenshotProducerEmitsReadableManifest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appendingPathComponent("inbox.png")
    let imageData = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="))
    try imageData.write(to: image)
    let taskRoot = directory.appendingPathComponent("tasks")
    let result = try await Subprocess.run(
        "/usr/bin/env",
        [
            "python3", artifactRepository.appendingPathComponent("scripts/task-shot.py").path,
            artifactTaskID, image.path, "Inbox after refresh", "--task-root", taskRoot.path, "--appearance", "dark",
        ])
    #expect(result.status == 0, "\(result.stderr)")
    let taskDirectory = taskRoot.appendingPathComponent(artifactTaskID)
    let manifest = try #require(
        try TaskArtifactReader.readScreenshots(
            at: taskDirectory.appendingPathComponent("shots.json"),
            expectedTaskID: artifactTaskID))
    #expect(manifest.screenshots == [.init(path: "shots/inbox.png", caption: "Inbox after refresh", appearance: .dark)])
    #expect(try Data(contentsOf: taskDirectory.appendingPathComponent("shots/inbox.png")) == imageData)
}
