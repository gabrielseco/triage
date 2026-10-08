import Foundation
import Security

public enum AnthropicError: LocalizedError {
    case noKey
    case http(Int, String)
    case refusal(String?)
    case empty

    public var errorDescription: String? {
        switch self {
        case .noKey: "No Anthropic API key. Set ANTHROPIC_API_KEY or add one in Settings."
        case .http(let code, let msg): "Anthropic HTTP \(code): \(msg)"
        case .refusal(let why): "Claude declined this request\(why.map { ": \($0)" } ?? "")."
        case .empty: "Claude returned no text."
        }
    }
}

/// Raw HTTP client for the Messages API (there's no official Swift SDK).
public struct AnthropicClient: Sendable {
    public static let defaultModel = "claude-opus-5-5"

    let apiKey: String
    let model: String

    public init(apiKey: String, model: String = AnthropicClient.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    public func complete(system: String, prompt: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // If safety classifiers decline, the server reruns on its recommended fallback model.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": model,
                "max_tokens": 16000,
                "fallbacks": "default",
                "system": system,
                "messages": [["role": "user", "content": prompt]],
            ] as [String: Any])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parse(data: data, statusCode: code)
    }

    /// Turns a Messages API response into the answer text, or a typed error. Pure, so it's unit-tested.
    static func parse(data: Data, statusCode code: Int) throws -> String {
        struct Response: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            struct StopDetails: Decodable { let explanation: String? }
            let content: [Block]
            let stopReason: String?
            let stopDetails: StopDetails?
            enum CodingKeys: String, CodingKey {
                case content
                case stopReason = "stop_reason"
                case stopDetails = "stop_details"
            }
        }
        struct ErrorBody: Decodable {
            struct APIError: Decodable { let message: String }
            let error: APIError
        }

        guard (200..<300).contains(code) else {
            let msg =
                (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                ?? String(decoding: data, as: UTF8.self)
            throw AnthropicError.http(code, msg)
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        if r.stopReason == "refusal" { throw AnthropicError.refusal(r.stopDetails?.explanation) }
        let text = r.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n\n")
        guard !text.isEmpty else { throw AnthropicError.empty }
        return text
    }
}

/// Minimal Keychain wrapper for the API key typed into Settings.
public enum Keychain {
    /// The app's own entries (the Anthropic key); GitLab tokens use `GitLabAuth.keychainService`.
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
