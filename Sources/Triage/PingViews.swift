import SwiftUI
import TriageCore

/// What the ping list and detail show: a Linear ping or a GitLab mention, both answered elsewhere.
protocol PingDisplay: Identifiable where ID == String {
    var symbol: String { get }
    /// "Mentioned" or "Thread reply".
    var label: String { get }
    /// "ENG-123" or "tiger !96285".
    var reference: String { get }
    var referenceTitle: String { get }
    var headline: String { get }
    var excerpt: String { get }
    var body: String { get }
    var url: URL { get }
    var date: Date { get }
    /// "Linear" or "GitLab", where the answer happens.
    var sourceName: String { get }
    /// What brings a dismissed one back.
    var dismissHelp: String { get }
}

extension LinearPing: PingDisplay {
    var symbol: String { kind.symbol }
    var label: String { kind == .mentioned ? "Mentioned" : "Thread reply" }
    var reference: String { issueKey }
    var referenceTitle: String { issueTitle }
    var date: Date { pingedAt }
    var sourceName: String { "Linear" }
    var dismissHelp: String { "Hide it without answering. A newer reply in this thread brings it back." }
}

extension GitLabMention: PingDisplay {
    var symbol: String { "at" }
    var label: String { "Mentioned" }
    var reference: String { target }
    var referenceTitle: String { targetTitle }
    var headline: String { "\(author) mentioned you" }
    var date: Date { createdAt }
    var sourceName: String { "GitLab" }
    var dismissHelp: String { "Hide it without answering. A new mention brings it back." }
}

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

/// The inbox column for GitLab › Mentioned.
struct MentionList: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        if store.visibleMentions.isEmpty, store.gitlabMentions.lastRefresh == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visibleMentions.isEmpty {
            EmptyState(
                "Inbox zero", systemImage: "checkmark.circle",
                description: "No GitLab mentions waiting on your reply.")
        } else {
            List(selection: $store.selection) {
                ForEach(store.visibleMentions) { PingRow(ping: $0).tag($0.id) }
            }
        }
    }
}

struct PingRow<Ping: PingDisplay>: View {
    let ping: Ping

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ping.symbol)
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: ping.reference).font(.caption.monospaced())
                    Text(ping.date, format: .relative(presentation: .named)).font(.caption)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(ping.headline).lineLimit(1)
                Text(ping.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .help(ping.referenceTitle)
    }
}

struct PingDetailView<Ping: PingDisplay>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    let ping: Ping

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
            Label(ping.label, systemImage: ping.symbol)
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text(ping.headline).font(.title2.weight(.semibold)).textSelection(.enabled)
            Link(String("\(ping.reference) — \(ping.referenceTitle)"), destination: ping.url)
                .multilineTextAlignment(.leading)
            Text("\(ping.sourceName) · \(ping.date.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                openURL(ping.url)
            } label: {
                Label("Open in \(ping.sourceName)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o")
            .help("Answer in \(ping.sourceName) (⌘O). It leaves Triage once you've replied.")
            Spacer()
            Menu {
                Button("1 hour") { store.snoozePing(ping.id, for: 3600) }
                Button("4 hours") { store.snoozePing(ping.id, for: 4 * 3600) }
                Button("Until tomorrow") { store.snoozePing(ping.id, for: 24 * 3600) }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .fixedSize()
            Button {
                store.dismissPing(ping.id)
            } label: {
                Label("Dismiss", systemImage: "checkmark")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .help(ping.dismissHelp)
        }
    }
}
