import SwiftUI
import TriageCore

struct ItemDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    let item: AttentionItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                status
                explanation
                Divider()
                Text("Evidence").font(.headline)
                ForEach(item.evidence, id: \.self) { EvidenceCard(evidence: $0) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(item.kind.title, systemImage: item.kind.symbol)
                    .foregroundStyle(item.severity.color)
                    .font(.subheadline.weight(.semibold))
                Text(item.severity.label).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(item.severity.color.opacity(0.15), in: Capsule())
            }
            Text(item.headline).font(.title2.weight(.semibold)).textSelection(.enabled)
            Link(String("\(item.pr.repo.fullName) #\(item.pr.number) — \(item.pr.title)"), destination: item.pr.url)
            Text(
                "by \(item.pr.author) · \(item.pr.headRef) · updated \(item.pr.updatedAt.formatted(.relative(presentation: .named)))"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            if item.kind.isFixable {
                Button {
                    Task { await store.explain(item) }
                } label: {
                    Label("Explain & propose fix", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.explanations[item.id] == .loading)
                .keyboardShortcut("e")

                Button {
                    Task { await store.fixInTerminal(item) }
                } label: {
                    Label("Fix in iTerm", systemImage: "terminal")
                }
                .help(
                    "Opens iTerm in a worktree for this PR and starts your harness (\(store.harnessCommand)) with the prompt"
                )
                .keyboardShortcut("f")

                Menu {
                    Button("For a chat (explain + propose)") {
                        Task { await store.copyPrompt(for: item, mode: .explain) }
                    }
                    Button("For Claude Code in your checkout") {
                        Task { await store.copyPrompt(for: item, mode: .claudeCode) }
                    }
                } label: {
                    Label("Copy prompt", systemImage: "doc.on.doc")
                }
                .fixedSize()
            }
            Spacer()
            Menu {
                Button("1 hour") { store.snooze(item, for: 3600) }
                Button("4 hours") { store.snooze(item, for: 4 * 3600) }
                Button("Until tomorrow") { store.snooze(item, for: 24 * 3600) }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .fixedSize()
            Button {
                store.dismiss(item)
            } label: {
                Label("Dismiss", systemImage: "checkmark")
            }
            .keyboardShortcut(.delete, modifiers: [])
            Button {
                openURL(item.pr.url)
            } label: {
                Label("Open", systemImage: "safari")
            }
            .keyboardShortcut("o")
        }
    }

    @ViewBuilder private var status: some View {
        if let s = store.actionStatus[item.id] {
            Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private var explanation: some View {
        switch store.explanations[item.id] {
        case .loading:
            HStack {
                ProgressView().controlSize(.small);
                Text("Gathering logs and diff, asking Claude…").foregroundStyle(.secondary)
            }
        case .done(let text):
            GroupBox {
                ScrollView(.vertical) {
                    Text(markdown(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
            } label: {
                Label("Claude", systemImage: "sparkles")
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

}

struct EvidenceCard: View {
    let evidence: Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(evidence.title).font(.subheadline.weight(.semibold))
                Spacer()
                if let url = evidence.url { Link(destination: url) { Image(systemName: "arrow.up.right.square") } }
            }
            if let d = evidence.detail, !d.isEmpty {
                Text(markdown(String(d.prefix(1500)))).font(.callout).foregroundStyle(.secondary).textSelection(
                    .enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}
