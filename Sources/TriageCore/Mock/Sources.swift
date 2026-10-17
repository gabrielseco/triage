import Foundation

/// The edges the app reads from outside, as the app sees them. The real clients and the mock both conform, so a
/// view or a rule never knows which it has (docs/plans/MOCK.md). `ForgeClient` is the fourth edge, in `Forge.swift`.

/// Linear's notifications, from which the pings are worked out.
public protocol LinearSource: Sendable {
    func notifications() async throws -> (notifications: [LinearNotification], warnings: [String])
}

extension LinearClient: LinearSource {}

/// GitLab @mentions waiting on the viewer, from a client that can list them.
public protocol MentionsSource: Sendable {
    func mentions() async throws -> [GitLabMention]
}

extension GitLabForge: MentionsSource {}

/// The Claude call behind Explain.
public protocol Explainer: Sendable {
    func complete(system: String, prompt: String) async throws -> String
}

extension AnthropicClient: Explainer {}
