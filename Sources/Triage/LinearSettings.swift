import SwiftUI
import TriageCore

/// Settings → Linear: the toggle, the key, and ping notifications.
struct LinearSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var linearKey = ""
    @State private var linearStatus: String?
    @State private var linearFailed = false

    /// Triage's own page in System Settings → Notifications.
    static let notificationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.rogal.triage")
        ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")

    static let linearHelp = """
        Mentions of you, and replies in threads you commented in, until you answer them in Linear. Each new \
        one notifies, then reminds you after 1 hour, 4 hours and once a day while it's waiting. Create a \
        personal API key with Read access under Linear → Settings → Security & access. Key source is a 1Password \
        secret reference or a helper script that prints the key; it's read once per session, and the Keychain \
        isn't used, so rebuilds don't ask for your password. Otherwise a pasted key is kept in the Keychain (or \
        set LINEAR_API_KEY).
        """

    var body: some View {
        @Bindable var store = store
        return Section {
            Toggle("Show Linear pings", isOn: $store.linearEnabled)
                .onChange(of: store.linearEnabled) { _, on in
                    reportLinear(nil)
                    if on { Task { await store.refreshLinear() } }
                }
            if store.linearEnabled {
                TextField(
                    "Key source", text: $store.linearKeyRef, prompt: Text("op://Vault/Linear/credential (optional)")
                )
                .font(.body.monospaced())
                if store.linearKeyRef.isEmpty {
                    SecureField("API key", text: $linearKey, prompt: Text("Paste a new key"))
                }
                HStack {
                    if store.linearKeyRef.isEmpty {
                        Button("Save key") {
                            do {
                                try store.saveLinearKey(linearKey)
                                linearKey = ""
                                reportLinear("Saved to Keychain")
                            } catch { reportLinear(error.localizedDescription, failed: true) }
                        }
                        .disabled(linearKey.isEmpty)
                    }
                    Button("Test") {
                        reportLinear("Checking…")
                        store.linear.keyFailure = nil
                        Task {
                            do {
                                let (notifications, _) = try await store.linearClient().notifications()
                                let open = LinearPings.classify(notifications, now: Date()).count
                                reportLinear("✓ Connected · \(open) waiting on you")
                            } catch { reportLinear(error.localizedDescription, failed: true) }
                        }
                    }
                    if let linearStatus {
                        Text(linearStatus).font(.caption).foregroundStyle(linearFailed ? .red : .secondary)
                    }
                }
                Toggle("Notify on every ping", isOn: $store.notifyPings)
                if store.notifyPings {
                    HStack {
                        Text("To keep them on screen until you click, set Triage to Alerts.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Notification Settings…") { openURL(Self.notificationSettingsURL) }
                            .help("System Settings → Notifications → Triage → Alerts")
                    }
                    if !Notifier.isAvailable {
                        Text("Notifications need the bundled app — launch with `triage`, not `swift run`.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Linear")
        } footer: {
            Text(Self.linearHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reportLinear(_ status: String?, failed: Bool = false) {
        linearStatus = status
        linearFailed = failed
    }
}
