import Foundation
import Security
import Testing

@testable import TriageCore

@Test func keychainErrorsExplainTheStatus() {
    let message = KeychainError(status: errSecAuthFailed).localizedDescription
    #expect(message.hasPrefix("Couldn't save to the Keychain: "))
    #expect(!message.contains("OSStatus"))  // macOS knows this status, so it gives a readable reason
}

/// An in-memory Keychain holding at most one item, which fails whichever calls the test says.
private final class FakeKeychain: @unchecked Sendable {  // only touched from one test at a time
    var stored: Data?
    var failing: Set<String> = []

    var ops: Keychain.Operations {
        Keychain.Operations(
            update: { _, changes in
                if self.failing.contains("update") { return errSecAuthFailed }
                guard self.stored != nil else { return errSecItemNotFound }
                self.stored = changes[kSecValueData as String] as? Data
                return errSecSuccess
            },
            add: { item in
                if self.failing.contains("add") { return errSecAuthFailed }
                self.stored = item[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { _ in
                if self.failing.contains("delete") { return errSecAuthFailed }
                defer { self.stored = nil }
                return self.stored == nil ? errSecItemNotFound : errSecSuccess
            })
    }
    var value: String? { stored.map { String(decoding: $0, as: UTF8.self) } }
}

@Test func savingAddsTheFirstKeyAndUpdatesAfterThat() throws {
    let keychain = FakeKeychain()
    try Keychain.set("sk-1", for: "anthropic", using: keychain.ops)
    try Keychain.set("sk-2", for: "anthropic", using: keychain.ops)
    #expect(keychain.value == "sk-2")
}

@Test func aFailedSaveKeepsThePreviousKey() throws {
    let keychain = FakeKeychain()
    try Keychain.set("sk-old", for: "anthropic", using: keychain.ops)
    keychain.failing = ["update", "add"]
    #expect(throws: KeychainError.self) { try Keychain.set("sk-new", for: "anthropic", using: keychain.ops) }
    #expect(keychain.value == "sk-old")
}

@Test func emptyRemovesTheKeyAndMissingIsFine() throws {
    let keychain = FakeKeychain()
    try Keychain.set("sk-1", for: "anthropic", using: keychain.ops)
    try Keychain.set("", for: "anthropic", using: keychain.ops)
    #expect(keychain.value == nil)
    try Keychain.set(nil, for: "anthropic", using: keychain.ops)  // nothing stored: still not an error
    keychain.failing = ["delete"]
    #expect(throws: KeychainError.self) { try Keychain.set(nil, for: "anthropic", using: keychain.ops) }
}
