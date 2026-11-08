import Foundation
import Security

/// Minimal Keychain wrapper for the tokens and keys typed into Settings.
public enum Keychain {
    /// The app's default service; GitLab and Linear use their own (`GitLabAuth`, `LinearAuth`).
    public static let service = "dev.rogal.triage"

    public static func get(_ account: String, service: String = service) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Replaces the stored value; nil or empty removes it. Throws if the Keychain refused, and then the
    /// previous value is still there: it's updated in place, never deleted first.
    public static func set(_ value: String?, for account: String, service: String = service) throws {
        try set(value, for: account, service: service, using: .system)
    }

    /// The three SecItem calls `set` needs, swappable so tests don't touch the real Keychain.
    struct Operations: Sendable {
        var update: @Sendable (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
        var add: @Sendable (_ item: [String: Any]) -> OSStatus
        var delete: @Sendable (_ query: [String: Any]) -> OSStatus

        static let system = Operations(
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) })
    }

    static func set(
        _ value: String?, for account: String, service: String = service, using ops: Operations
    ) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            let deleted = ops.delete(base)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                throw KeychainError(status: deleted)
            }
            return
        }
        let data = Data(value.utf8)
        let updated = ops.update(base, [kSecValueData as String: data])
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var add = base
        add[kSecValueData as String] = data
        let added = ops.add(add)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Couldn't save to the Keychain: \(reason)"
    }
}
