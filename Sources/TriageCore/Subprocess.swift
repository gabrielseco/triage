import Foundation

/// Runs a command off the main actor (callers are often `@MainActor`, and `waitUntilExit` would freeze the UI).
public enum Subprocess {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        public var trimmedStdout: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public static func run(_ executable: String, _ arguments: [String]) async throws -> Output {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            // Drain stderr concurrently: a full stderr pipe would block the process before stdout hits EOF.
            let errHandle = err.fileHandleForReading
            let errData = Task.detached { errHandle.readDataToEndOfFile() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Output(
                status: p.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: await errData.value, as: UTF8.self))
        }.value
    }
}
