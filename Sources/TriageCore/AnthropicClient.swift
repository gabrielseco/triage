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
    public static let defaultModel = "claude-opus-5"

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

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
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
        struct ErrorBody: Decodable { struct E: Decodable { let message: String }; let error: E }

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
    static let service = "dev.rogal.triage"

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
