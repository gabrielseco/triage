import Foundation

/// Version 1 acceptance criteria and their evidence, stored as verdict.json.
public struct TaskVerdict: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case pass, fail }

    public struct Criterion: Codable, Equatable, Sendable {
        public let text: String
        public let pass: Bool
        public let evidence: [String]

        public init(text: String, pass: Bool, evidence: [String]) {
            self.text = text
            self.pass = pass
            self.evidence = evidence
        }
    }

    public let schemaVersion: Int
    public let taskID: String
    public let verdict: Outcome
    public let criteria: [Criterion]

    public init(taskID: String, verdict: Outcome, criteria: [Criterion]) {
        schemaVersion = 1
        self.taskID = taskID
        self.verdict = verdict
        self.criteria = criteria
    }
}

/// Version 1 screenshot references, stored as shots.json beside the shots directory.
public struct TaskScreenshotManifest: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, Sendable { case light, dark }

    public struct Screenshot: Codable, Equatable, Sendable {
        public let path: String
        public let caption: String
        public let appearance: Appearance?
        public let criterion: String?

        public init(path: String, caption: String, appearance: Appearance? = nil, criterion: String? = nil) {
            self.path = path
            self.caption = caption
            self.appearance = appearance
            self.criterion = criterion
        }
    }

    public let schemaVersion: Int
    public let taskID: String
    public let screenshots: [Screenshot]

    public init(taskID: String, screenshots: [Screenshot]) {
        schemaVersion = 1
        self.taskID = taskID
        self.screenshots = screenshots
    }
}

/// Version 1 review findings, stored as reviews/<source>.json.
public struct TaskReview: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case blocking, warning, suggestion }

    public struct Finding: Codable, Equatable, Sendable {
        public let severity: Severity
        public let message: String
        public let file: String?
        public let line: Int?

        public init(severity: Severity, message: String, file: String? = nil, line: Int? = nil) {
            self.severity = severity
            self.message = message
            self.file = file
            self.line = line
        }
    }

    public let schemaVersion: Int
    public let taskID: String
    public let source: String
    public let findings: [Finding]

    public init(taskID: String, source: String, findings: [Finding]) {
        schemaVersion = 1
        self.taskID = taskID
        self.source = source
        self.findings = findings
    }
}

/// One version 1 events.jsonl record. Unknown kinds remain readable for future producers.
public struct TaskEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let taskID: String
    public let id: UUID
    public let timestamp: String
    public let kind: String
    public let payload: [String: String]

    public init(taskID: String, id: UUID, timestamp: String, kind: String, payload: [String: String]) {
        schemaVersion = 1
        self.taskID = taskID
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.payload = payload
    }
}

/// Structural errors are separate from JSON decoding and file I/O errors.
public enum TaskArtifactError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidTaskID(String)
    case taskMismatch(expected: String, actual: String)
    case unsafeScreenshotPath(String)
    case invalidTimestamp(String)
    case invalidUTF8
}

/// Reads artifact data without launching processes or depending on the app target.
/// Callers doing disk I/O should run the read methods off the main actor.
public enum TaskArtifactReader {
    private struct Header: Decodable {
        let schemaVersion: Int
        let taskID: String
    }

    public static func decodeVerdict(_ data: Data, expectedTaskID: String) throws -> TaskVerdict {
        try decode(TaskVerdict.self, data: data, expectedTaskID: expectedTaskID)
    }

    public static func decodeScreenshots(_ data: Data, expectedTaskID: String) throws -> TaskScreenshotManifest {
        let manifest = try decode(TaskScreenshotManifest.self, data: data, expectedTaskID: expectedTaskID)
        for shot in manifest.screenshots {
            let parts = shot.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.first == "shots",
                !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                !shot.path.contains("\\"), !shot.path.contains("%"), !shot.path.contains("\0")
            else { throw TaskArtifactError.unsafeScreenshotPath(shot.path) }
        }
        return manifest
    }

    public static func decodeReview(_ data: Data, expectedTaskID: String) throws -> TaskReview {
        try decode(TaskReview.self, data: data, expectedTaskID: expectedTaskID)
    }

    public static func decodeEvents(_ data: Data, expectedTaskID: String) throws -> [TaskEvent] {
        guard let text = String(data: data, encoding: .utf8) else { throw TaskArtifactError.invalidUTF8 }
        return try text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let event = try decode(TaskEvent.self, data: Data(trimmed.utf8), expectedTaskID: expectedTaskID)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: event.timestamp)
            formatter.formatOptions = [.withInternetDateTime]
            guard fractional != nil || formatter.date(from: event.timestamp) != nil else {
                throw TaskArtifactError.invalidTimestamp(event.timestamp)
            }
            return event
        }
    }

    public static func readVerdict(at url: URL, expectedTaskID: String) throws -> TaskVerdict? {
        try read(at: url) { try decodeVerdict($0, expectedTaskID: expectedTaskID) }
    }

    public static func readScreenshots(at url: URL, expectedTaskID: String) throws -> TaskScreenshotManifest? {
        try read(at: url) { try decodeScreenshots($0, expectedTaskID: expectedTaskID) }
    }

    public static func readReview(at url: URL, expectedTaskID: String) throws -> TaskReview? {
        try read(at: url) { try decodeReview($0, expectedTaskID: expectedTaskID) }
    }

    public static func readEvents(at url: URL, expectedTaskID: String) throws -> [TaskEvent]? {
        try read(at: url) { try decodeEvents($0, expectedTaskID: expectedTaskID) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data, expectedTaskID: String) throws -> T {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == 1 else { throw TaskArtifactError.unsupportedVersion(header.schemaVersion) }
        for taskID in [expectedTaskID, header.taskID] {
            guard taskID.range(of: "^[a-z0-9]+(-[a-z0-9]+)*\\z", options: .regularExpression) != nil else {
                throw TaskArtifactError.invalidTaskID(taskID)
            }
        }
        guard header.taskID == expectedTaskID else {
            throw TaskArtifactError.taskMismatch(expected: expectedTaskID, actual: header.taskID)
        }
        return try decoder.decode(type, from: data)
    }

    private static func read<T>(at url: URL, decode: (Data) throws -> T) throws -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try decode(data)
    }
}
