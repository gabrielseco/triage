import Security
import Testing

@testable import TriageCore

@Test func keychainErrorsExplainTheStatus() {
    let message = KeychainError(status: errSecAuthFailed).localizedDescription
    #expect(message.hasPrefix("Couldn't save to the Keychain: "))
    #expect(!message.contains("OSStatus"))  // macOS knows this status, so it gives a readable reason
}
