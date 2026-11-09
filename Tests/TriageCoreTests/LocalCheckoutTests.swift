import Testing

@testable import TriageCore

private let repo = RepoRef(owner: "remoteoss", name: "remote-flows")

@Test func originMatchingIgnoresProtocolAndSuffix() {
    #expect(LocalCheckout.originMatches("git@github.com:remoteoss/remote-flows.git", repo))
    #expect(LocalCheckout.originMatches("https://github.com/RemoteOSS/remote-flows", repo))
    #expect(!LocalCheckout.originMatches("git@github.com:remoteoss/remote-flows-legacy.git", repo))
}

@Test func keyReferenceRejectsNonExecutablePaths() async {
    await #expect(throws: OnePasswordError.self) { try await KeyReference.read("/definitely/not/here.sh") }
    await #expect(throws: OnePasswordError.self) { try await KeyReference.read("") }
}
