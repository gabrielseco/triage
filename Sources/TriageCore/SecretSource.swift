import Foundation

/// Where a token or key comes from, in order: its environment variable, a key source (`KeyReference`), then the
/// Keychain. With a key source set the Keychain isn't read at all, so a rebuilt, re-signed app doesn't ask for
/// the login password again.
public enum SecretSource {
    public static func resolve(
        env: String?, reference: String, keychain: () -> String?,
        read: (String) async throws -> String = KeyReference.read
    ) async throws -> String? {
        if let env, !env.isEmpty { return env }
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ref.isEmpty { return try await read(ref) }
        return keychain()
    }
}

public enum GitLabAuth {
    /// Where Settings keeps a host's token: its own Keychain service, with the host as the account.
    public static let keychainService = "dev.rogal.triage.gitlab"

    /// GITLAB_TOKEN env var, else the key source (`op://…` or a helper script), else the Keychain entry for `host`.
    public static func token(host: String, reference: String = "") async throws -> String? {
        try await SecretSource.resolve(
            env: ProcessInfo.processInfo.environment["GITLAB_TOKEN"], reference: reference,
            keychain: { Keychain.get(host, service: keychainService) })
    }
}

public enum LinearAuth {
    /// Where Settings keeps the key: its own Keychain service, one account.
    public static let keychainService = "dev.rogal.triage.linear"
    public static let keychainAccount = "api.linear.app"

    /// LINEAR_API_KEY env var, else the key source (`op://…` or a helper script), else the Keychain entry.
    public static func key(reference: String = "") async throws -> String? {
        try await SecretSource.resolve(
            env: ProcessInfo.processInfo.environment["LINEAR_API_KEY"], reference: reference,
            keychain: { Keychain.get(keychainAccount, service: keychainService) })
    }
}
