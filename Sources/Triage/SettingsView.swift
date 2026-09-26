import SwiftUI
import TriageCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var key = ""
    @State private var saved = false
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var testResult: String?

    static let keySourceHelp = """
        Key source is a 1Password secret reference (item → field menu → Copy Secret Reference) \
        or a key helper script that prints the key, like Claude Code's apiKeyHelper. It wins over \
        the other options; the key is read once per session and kept in memory only.
        """

    static let harnessHelp = """
        Runs in a worktree next to your checkout (e.g. ~/remote/remote-flows-pr-1392), in an \
        interactive zsh so .zshrc functions work. {prompt_file} is the prompt. Examples: \
        cursor-agent "$(cat {prompt_file})" · gemini "$(cat {prompt_file})"
        """

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                TextField(
                    "Key source", text: $store.onePasswordRef,
                    prompt: Text("op://Vault/Item/credential or ~/.claude/anthropic_key.sh")
                )
                .font(.body.monospaced())
                HStack {
                    Button("Test") {
                        testResult = "Reading key…"
                        Task {
                            do {
                                _ = try await store.resolveAPIKey()
                                testResult = "✓ Key read from \(store.keySource.rawValue)"
                            } catch { testResult = error.localizedDescription }
                        }
                    }
                    .disabled(store.keySource == .none)
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                }
                if store.keySource != .onePassword {
                    SecureField("…or paste a key (saved to Keychain)", text: $key)
                    Button(saved ? "Saved to Keychain" : "Save key") {
                        Keychain.set(key, for: "anthropic")
                        saved = true
                        key = ""
                    }
                    .disabled(key.isEmpty)
                }
                TextField("Model", text: $store.model)
            } header: {
                Text("Claude")
            } footer: {
                Text("Using: \(store.keySource.rawValue). " + Self.keySourceHelp)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Harness command", text: $store.harnessCommand)
                    .font(.body.monospaced())
                Button("Reset to Claude Code") { store.harnessCommand = Handoff.defaultHarnessCommand }
            } header: {
                Text("Fix in iTerm")
            } footer: {
                Text(Self.harnessHelp)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Digest notifications") {
                TextField(
                    "Hours (24h, comma-separated)",
                    text: Binding(
                        get: { store.digestHours.map(String.init).joined(separator: ", ") },
                        set: {
                            store.digestHours = $0.split(separator: ",").compactMap {
                                Int($0.trimmingCharacters(in: .whitespaces))
                            }.filter { (0..<24).contains($0) }.sorted()
                        }
                    ))
                Toggle("Weekdays only", isOn: $store.digestWeekdaysOnly)
                Toggle(
                    "Open Triage at login",
                    isOn: Binding(
                        get: { loginItem },
                        set: { on in
                            do { try LoginItem.set(on); loginError = nil } catch {
                                loginError = error.localizedDescription
                            }
                            loginItem = LoginItem.isEnabled
                        }
                    ))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                if !Notifier.isAvailable {
                    Text("Notifications need the bundled app — launch with `triage`, not `swift run`.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Send a digest now") { Task { await store.sendDigest(force: true) } }
            }
            Section("GitHub") {
                Text(
                    ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil
                        ? "Using GITHUB_TOKEN from the environment."
                        : "Using the `gh` CLI token\(store.viewer.map { " (signed in as \($0))" } ?? "")."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }
}
