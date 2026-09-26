import AppKit
import Foundation
import TriageCore

/// Prompts, the Claude explain call, and where the API key comes from.
extension AppStore {
    // MARK: - AI

    func buildPrompt(for item: AttentionItem, mode: PromptMode) async -> String {
        var ctx = PromptContext()
        if let token = await GitHubAuth.resolveToken() {
            let gh = GitHubClient(token: token)
            let repo = item.pr.repo
            if item.kind == .ciFailure {
                for e in item.evidence.prefix(3) {
                    guard let id = e.checkRunID else { continue }
                    if let log = await gh.jobLog(repo, jobID: id) {
                        ctx.checkOutputs.append((e.title, log))
                    } else if let out = await gh.checkRunOutput(repo, id: id) {
                        ctx.checkOutputs.append((e.title, out))
                    }
                }
            }
            ctx.diff = await gh.diff(repo, number: item.pr.number)
        }
        return PromptBuilder.prompt(for: item, context: ctx, mode: mode)
    }

    func copyPrompt(for item: AttentionItem, mode: PromptMode) async {
        actionStatus[item.id] = "Fetching logs and diff…"
        let text = await buildPrompt(for: item, mode: mode)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actionStatus[item.id] = "Copied prompt (\(text.count / 1000) KB) to the clipboard"
    }

    enum KeySource: String {
        case onePassword = "1Password / key helper", environment = "ANTHROPIC_API_KEY", keychain = "Keychain", none =
            "not set"
    }

    /// Which key Explain will use. A configured 1Password reference wins: it's the explicit choice made in
    /// this app (e.g. the work key), whereas the environment may hold an unrelated personal key.
    var keySource: KeySource {
        if !onePasswordRef.isEmpty { return .onePassword }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return .environment }
        if Keychain.get("anthropic") != nil { return .keychain }
        return .none
    }

    func resolveAPIKey() async throws -> String {
        switch keySource {
        case .onePassword:
            if let k = cachedOnePasswordKey { return k }
            let k = try await KeyReference.read(onePasswordRef)
            cachedOnePasswordKey = k
            return k
        case .environment, .keychain, .none:
            // keySource picked the first source that has a value; read it the same way.
            guard let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? Keychain.get("anthropic"),
                !k.isEmpty
            else { throw AnthropicError.noKey }
            return k
        }
    }

    func explain(_ item: AttentionItem) async {
        explanations[item.id] = .loading
        do {
            let key = try await resolveAPIKey()
            let prompt = await buildPrompt(for: item, mode: .explain)
            let text = try await AnthropicClient(apiKey: key, model: model)
                .complete(system: PromptBuilder.systemPrompt, prompt: prompt)
            explanations[item.id] = .done(text)
        } catch {
            // A rotated key in 1Password: forget the cached one so the next try re-reads it.
            if case AnthropicError.http(401, _) = error { cachedOnePasswordKey = nil }
            explanations[item.id] = .failed(error.localizedDescription)
        }
    }
}
