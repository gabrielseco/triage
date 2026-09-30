import SwiftUI
import TriageCore

/// The inbox column for a Linear sidebar row.
struct PingList: View {
    @Environment(AppStore.self) private var store
    let kind: LinearPing.Kind

    var body: some View {
        @Bindable var store = store
        if store.visiblePings.isEmpty, let error = store.linear.errors.first {
            EmptyState("Can't reach Linear", systemImage: "exclamationmark.triangle", description: error) {
                SettingsLink { Text("Open Settings") }
            }
        } else if store.visiblePings.isEmpty, store.linear.lastRefresh == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visiblePings.isEmpty {
            EmptyState(
                "Inbox zero", systemImage: "checkmark.circle",
                description: kind == .mentioned
                    ? "No mentions waiting on your answer." : "No replies waiting in your threads.")
        } else {
            List(selection: $store.selection) {
                ForEach(store.visiblePings) { PingRow(ping: $0).tag($0.id) }
            }
        }
    }
}

struct PingRow: View {
    let ping: LinearPing

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ping.kind.symbol)
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: ping.issueKey).font(.caption.monospaced())
                    Text(ping.pingedAt, format: .relative(presentation: .named)).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(ping.headline).lineLimit(1)
                Text(ping.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .help(ping.issueTitle)
    }
}

struct PingDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    let ping: LinearPing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                Divider()
                Text(markdown(CommentText.readable(ping.body)))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ping.kind == .mentioned ? "Mentioned" : "Thread reply", systemImage: ping.kind.symbol)
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text(ping.headline).font(.title2.weight(.semibold)).textSelection(.enabled)
            Link(String("\(ping.issueKey) — \(ping.issueTitle)"), destination: ping.url)
                .multilineTextAlignment(.leading)
            Text("Linear · \(ping.pingedAt.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                openURL(ping.url)
            } label: {
                Label("Open in Linear", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o")
            .help("Answer in Linear (⌘O). It leaves Triage once you've replied.")
            Spacer()
            Menu {
                Button("1 hour") { store.snooze(ping, for: 3600) }
                Button("4 hours") { store.snooze(ping, for: 4 * 3600) }
                Button("Until tomorrow") { store.snooze(ping, for: 24 * 3600) }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .fixedSize()
            Button {
                store.dismiss(ping)
            } label: {
                Label("Dismiss", systemImage: "checkmark")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .help("Hide it without answering. A newer reply in this thread brings it back.")
        }
    }
}
