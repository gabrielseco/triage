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
        try await withCheckedThrowingContinuation { cont in
            // Blocking reads and waitUntilExit run on GCD, not the cooperative pool: GCD adds threads when
            // these block, the pool doesn't, so concurrent calls (op on Touch ID, gh, git) can't starve it.
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { return cont.resume(throwing: error) }
                // Drain stderr concurrently: a full stderr pipe would block the process before stdout hits EOF.
                let errData = DataBox()
                let group = DispatchGroup()
                let errHandle = err.fileHandleForReading
                DispatchQueue.global().async(group: group) { errData.value = errHandle.readDataToEndOfFile() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(
                    returning: Output(
                        status: p.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData.value, as: UTF8.self)))
            }
        }
    }

    /// Hands stderr bytes from the drain block back to the reader; `group.wait()` orders the write before the read.
    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }
}
