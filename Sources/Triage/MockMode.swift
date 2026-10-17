import Foundation
import SwiftUI
import TriageCore

/// Mock mode (docs/plans/MOCK.md): `TRIAGE_FIXTURE=<scenario.json>` runs the app on data from one file and reaches
/// nothing real. Each edge the app reads from outside asks `MockMode.world` first; this file holds what is shared.
enum MockMode {
    /// The scenario's data, or nil for the real app. A set but unusable `TRIAGE_FIXTURE` ends the process: a
    /// typo must never fall back to the real app, whose Keychain and forge tokens the mock is there to avoid.
    static let world: MockWorld? = {
        do {
            guard let scenario = try MockScenario.fromEnvironment() else { return nil }
            return try MockWorld(scenario)
        } catch {
            FileHandle.standardError.write(Data("Triage: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }()

    static var isActive: Bool { world != nil }

    static let title = "Triage — mock data"

    /// Where mock mode keeps settings and state, emptied at every start, so nothing carries over and the installed
    /// app's settings are never read or written.
    /// Not the bundle id `scripts/mock.sh` gives the build: macOS refuses a suite named after the app itself.
    static let defaultsSuite = "dev.rogal.triage.mock-state"

    /// Called first at launch. Any request that still tries the network fails and says so; every client reads
    /// `URLSession.shared`, which honours a registered protocol.
    static func install() {
        guard isActive else { return }
        URLProtocol.registerClass(BlockedRequests.self)
    }

    /// Throws in mock mode, for what writes outside the process (a Keychain item, the login item).
    static func refuse(_ what: String) throws {
        if isActive { throw MockError.blocked(what) }
    }

    /// Links do nothing in mock mode: its URLs are made up.
    @MainActor static var openURL: OpenURLAction { OpenURLAction { _ in isActive ? .handled : .systemAction } }
}

/// Fails every request with a message naming the URL, so a client that was missed shows in the UI and the log.
final class BlockedRequests: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url?.absoluteString ?? "a request"
        client?.urlProtocol(self, didFailWithError: MockError.blocked("the network (\(url))"))
    }
}
