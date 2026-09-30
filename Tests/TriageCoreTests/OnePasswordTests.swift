import Testing

@testable import TriageCore

@Test(arguments: ["", "sk-ant-abc", "op://only-vault", "op://Vault/Item"])
func malformedReferencesAreRejectedBeforeCallingOp(_ ref: String) async {
    await #expect(throws: OnePasswordError.self) { try await OnePassword.read(ref) }
}

private struct Unreachable: Error {}

@Test func theEnvironmentWinsOverEverything() async throws {
    let v = try await SecretSource.resolve(
        env: "from-env", reference: "op://V/I/f", keychain: { "from-keychain" }, read: { _ in throw Unreachable() })
    #expect(v == "from-env")
}

@Test func aKeySourceIsReadInsteadOfTheKeychain() async throws {
    // The Keychain must not even be asked: a re-signed build would prompt for the login password.
    let v = try await SecretSource.resolve(
        env: "", reference: "  op://V/I/f\n",
        keychain: {
            Issue.record("Keychain read"); return nil
        },
        read: { "read \($0)" })
    #expect(v == "read op://V/I/f")
}

@Test func withoutAKeySourceItFallsBackToTheKeychain() async throws {
    let v = try await SecretSource.resolve(
        env: nil, reference: " ", keychain: { "from-keychain" }, read: { _ in throw Unreachable() })
    #expect(v == "from-keychain")
}

@Test func aFailingKeySourceIsAnErrorNotAFallback() async {
    await #expect(throws: Unreachable.self) {
        _ = try await SecretSource.resolve(
            env: nil, reference: "op://V/I/f", keychain: { "stale" }, read: { _ in throw Unreachable() })
    }
}
