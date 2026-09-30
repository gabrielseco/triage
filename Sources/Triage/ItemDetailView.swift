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
                if let ci = item.pr.ciStatus {
                    CIBadge(status: ci, url: item.pr.checksURL, forge: item.pr.repo.forge)
                }
            }
            Text(item.headline).font(.title2.weight(.semibold)).textSelection(.enabled)
            Link(String("\(item.pr.repo.fullName) \(item.pr.ref) — \(item.pr.title)"), destination: item.pr.url)
            let updated = item.pr.updatedAt.formatted(.relative(presentation: .named))
            Text("by \(item.pr.author) · \(item.pr.headRef) · updated \(updated)")
                .font(.caption).foregroundStyle(.secondary)
            if let summary = item.pr.summary {
                Text(markdown(summary)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var actions: some View {
        HStack {
            if item.kind == .readyToMerge, store.can(.merge, item.pr) {
                Button {
                    store.confirming = PRConfirmation(action: .merge, item: item)
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.pr.mergeBlocker != nil)
                .help("\(item.pr.mergeMethod.title) on \(forgeName) (⇧⌘M)")
            }
            if store.canApprove(item.pr) {
                Button {
                    Task { await store.approvePullRequest(item) }
                } label: {
                    Label("Approve", systemImage: "checkmark.seal")
                }
                .help("Approve \(item.pr.author)'s PR on \(forgeName) (⇧⌘A)")
            }
            if item.kind.isFixable {
                Button {
                    Task { await store.explain(item) }
                } label: {
                    Label("Explain & propose fix", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.explanations[item.id] == .loading)
                .keyboardShortcut("e")

                if store.can(.checkout, item.pr) {
                    Button {
                        Task { await store.fixInTerminal(item) }
                    } label: {
                        Label("Fix in iTerm", systemImage: "terminal")
                    }
                    .help("Opens iTerm in a worktree for this PR and runs \(store.harnessCommand) with the prompt")
                    .keyboardShortcut("f")
                }

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
            if store.can(.checkout, item.pr) {
                Menu {
                    Button("Copy prompt for a chat") { Task { await store.copyExplainPRPrompt(for: item) } }
                } label: {
                    Label("Explain PR", systemImage: "text.magnifyingglass")
                } primaryAction: {
                    Task { await store.explainPRInTerminal(item) }
                }
                .fixedSize()
                .help(
                    "Open Claude in iTerm in this PR's worktree to walk you through it (arrow: copy the prompt instead)"
                )
                .keyboardShortcut("e", modifiers: [.command, .shift])
            } else {
                // No worktree without checkout: the prompt for a chat is what's left.
                Button {
                    Task { await store.copyExplainPRPrompt(for: item) }
                } label: {
                    Label("Explain PR", systemImage: "text.magnifyingglass")
                }
                .help("Copy a prompt that walks you through this merge request, for a chat")
                .keyboardShortcut("e", modifiers: [.command, .shift])
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
            Menu {
                PullRequestActions(item: item)
            } label: {
                Label("Open", systemImage: "safari")
            } primaryAction: {
                openURL(item.pr.primaryURL(viewer: viewer))
            }
            .fixedSize()
            .help(
                item.pr.primaryURL(viewer: viewer) == item.pr.url
                    ? "Open your PR's conversation on \(forgeName) (arrow: more)"
                    : "Open the PR's changes on \(forgeName) (arrow: more)")
        }
        .confirmationDialog(
            confirmTitle, isPresented: confirmShown, titleVisibility: .visible, presenting: store.confirming
        ) { c in
            switch c.action {
            case .merge:
                let method = c.item.pr.mergeMethod.title
                // Someone else's PR you haven't approved: approving is the default, merging as-is the fallback.
                if store.canApprove(c.item.pr) {
                    Button("Approve, then \(method.lowercased())") {
                        Task { await store.mergePullRequest(c.item, approvingFirst: true) }
                    }
                    Button("\(method) without approving") { Task { await store.mergePullRequest(c.item) } }
                } else {
                    Button(method) { Task { await store.mergePullRequest(c.item) } }
                }
            case .close:
                Button("Close PR", role: .destructive) { Task { await store.closePullRequest(c.item) } }
            }
        } message: { c in
            Text(c.action == .merge ? mergeMessage : closeMessage)
        }
    }

    /// Only the item on screen answers a confirmation asked for it.
    private var confirmShown: Binding<Bool> {
        Binding(
            get: { store.confirming?.item.id == item.id },
            set: { if !$0 { store.confirming = nil } })
    }

    private var confirmTitle: String {
        let verb = store.confirming?.action == .close ? "Close" : "Merge"
        return "\(verb) \(item.pr.repo.fullName) \(item.pr.ref)?"
    }

    private var mergeMessage: String {
        let warnings = item.pr.mergeWarnings.map { "⚠︎ \($0)" }.joined(separator: "\n")
        return "\(item.pr.title)\n\n\(item.pr.headRef) → base branch" + (warnings.isEmpty ? "" : "\n\n\(warnings)")
    }

    /// Leads with the author when it's someone else's PR, so a teammate's work isn't closed by mistake.
    private var closeMessage: String {
        let owner = item.pr.author == viewer ? "" : "This is \(item.pr.author)'s PR.\n\n"
        return "\(owner)\(item.pr.title)\n\nIt's closed on \(forgeName) without merging. You can reopen it there."
    }

    private var viewer: String? { store.viewer(for: item.pr.repo.forge) }
    private var forgeName: String { item.pr.repo.forge.name }

    @ViewBuilder private var status: some View {
        if let s = store.actionStatus[item.id] {
            Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private var explanation: some View {
        switch store.explanations[item.id] {
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
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
                // Readable first, so a bot's HTML boilerplate doesn't use up the 1500 characters.
                Text(markdown(String(CommentText.readable(d).prefix(1500)))).font(.callout).foregroundStyle(.secondary)
                    .textSelection(
                        .enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// CI at a glance next to the item's kind; opens the PR's Checks tab.
struct CIBadge: View {
    let status: CIStatus
    let url: URL
    let forge: Forge

    var body: some View {
        Link(destination: url) {
            Label(status.label, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
        }
        .help("Open the checks on \(forge.name)")
    }

    private var symbol: String {
        switch status.state {
        case .failing: "xmark.circle.fill"
        case .running: "clock.fill"
        case .passed: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch status.state {
        case .failing: .red
        case .running: .orange
        case .passed: .green
        }
    }
}

extension View {
    @ViewBuilder func shortcut(
        _ key: KeyEquivalent, modifiers: EventModifiers = .command, if enabled: Bool
    ) -> some View {
        if enabled { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

/// Approve, merge, close and open on the forge: the item detail's Open menu and the Pull Request menu in the menu
/// bar. Actions the forge can't do yet are left out.
/// Shortcuts are bound in the menu bar only, so a key press can't fire both copies.
struct PullRequestActions: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    let item: AttentionItem
    var inMenuBar = false

    var body: some View {
        if store.canApprove(item.pr) {
            Button("Approve") { Task { await store.approvePullRequest(item) } }
                .shortcut("a", modifiers: [.command, .shift], if: inMenuBar)
        }
        if store.can(.merge, item.pr) {
            Button("Merge…") { confirm(.merge) }
                .shortcut("m", modifiers: [.command, .shift], if: inMenuBar)
                .disabled(item.pr.mergeBlocker != nil)
        }
        if store.can(.close, item.pr) {
            Button("Close PR…") { confirm(.close) }
        }
        if store.can(.approve, item.pr) || store.can(.merge, item.pr) || store.can(.close, item.pr) {
            Divider()
        }
        // ⌘O goes where Open does (the conversation for your own PR, the changes otherwise), ⌘⇧O to the other.
        if item.pr.primaryURL(viewer: store.viewer(for: item.pr.repo.forge)) == item.pr.url {
            openConversation.shortcut("o", if: inMenuBar)
            openChanges.shortcut("o", modifiers: [.command, .shift], if: inMenuBar)
        } else {
            openChanges.shortcut("o", if: inMenuBar)
            openConversation.shortcut("o", modifiers: [.command, .shift], if: inMenuBar)
        }
        if store.can(.merge, item.pr), let blocker = item.pr.mergeBlocker {
            Divider()
            Text("Can't merge: \(blocker.lowercased())")
        }
    }

    private var openChanges: some View {
        Button("Open Changes on \(item.pr.repo.forge.name)") { openURL(item.pr.changesURL) }
    }

    private var openConversation: some View {
        Button("Open Conversation on \(item.pr.repo.forge.name)") { openURL(item.pr.url) }
    }

    /// The dialog lives in the item detail, so bring the window back if it was closed.
    private func confirm(_ action: PRConfirmation.Action) {
        store.confirming = PRConfirmation(action: action, item: item)
        store.showMainWindow()
    }
}
