import Testing
@testable import TriageCore

@Test(arguments: ["", "sk-ant-abc", "op://only-vault", "op://Vault/Item"])
func malformedReferencesAreRejectedBeforeCallingOp(_ ref: String) async {
    await #expect(throws: OnePasswordError.self) { try await OnePassword.read(ref) }
}
