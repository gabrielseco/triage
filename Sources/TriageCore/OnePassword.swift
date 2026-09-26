import Foundation

public enum OnePasswordError: LocalizedError {
    case cliMissing
    case badReference
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cliMissing: "1Password CLI (`op`) not found. Install it with `brew install 1password-cli`."
        case .badReference: "The 1Password reference should look like op://Vault/Item/field."
        case .failed(let msg): "API key: \(msg)"
        }
    }
}

/// Where the Anthropic key comes from: an `op://` reference, or the path of a helper script that prints
/// the key. The second is the same contract as Claude Code's `apiKeyHelper` (e.g. ~/.claude/anthropic_key.sh),
/// so Triage and Claude Code can share one key source.
public enum KeyReference {
    public static func read(_ reference: String) async throws -> String {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref.hasPrefix("op://") { return try await OnePassword.read(ref) }
        let path = (ref as NSString).expandingTildeInPath
        guard !ref.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw OnePasswordError.failed(
                "\(ref.isEmpty ? "no reference" : ref) is neither an op:// reference nor an executable key helper")
        }
        return try await OnePassword.run(path, [])
    }
}

/// Reads a secret with `op read op://Vault/Item/field`. With 1Password's "Integrate with 1Password CLI"
/// setting on, this shows a Touch ID prompt; the secret never touches disk.
public enum OnePassword {
    static let candidates = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]

    public static var cliPath: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public static func read(_ reference: String) async throws -> String {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.hasPrefix("op://"), ref.split(separator: "/").count >= 4 else { throw OnePasswordError.badReference }
        guard let op = cliPath else { throw OnePasswordError.cliMissing }
        return try await run(op, ["read", "--no-newline", ref])
    }

    /// Runs a command that prints a secret on stdout.
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        // `op` blocks while the Touch ID prompt is up; keep it off the main thread.
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: errData, as: UTF8.self)
                    .replacingOccurrences(of: #"^\[ERROR\] [0-9/: ]+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw OnePasswordError.failed(
                    msg.isEmpty
                        ? "\(URL(fileURLWithPath: executable).lastPathComponent) exited with \(p.terminationStatus)"
                        : msg)
            }
            let secret = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { throw OnePasswordError.failed("no key was returned") }
            return secret
        }.value
    }
}
