import SwiftUI
import TriageCore

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            InboxList()
                .navigationSplitViewColumnWidth(min: 340, ideal: 420)
        } detail: {
            if let item = store.selectedItem {
                ItemDetailView(item: item).id(item.id)
            } else if let ping = store.selectedPing {
                PingDetailView(ping: ping).id(ping.id)
            } else if let mention = store.selectedMention {
                PingDetailView(ping: mention).id(mention.id)
            } else {
                EmptyState(
                    "Nothing selected", systemImage: "tray",
                    description: store.repos.isEmpty
                        ? "Add a repo in the sidebar to start watching." : "Pick an item from the inbox.")
            }
        }
        // Status, not a control: as the window subtitle it sits under the title, like Mail's message count,
        // instead of in a toolbar capsule that reads as a button.
        .navigationTitle("Triage")
        .navigationSubtitle(store.summaryLine)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $store.onlyMine) {
                    Label(
                        store.onlyMine ? "Mine" : "Everyone's", systemImage: store.onlyMine ? "person.fill" : "person.2"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .help(
                    store.onlyMine
                        ? "Showing only PRs authored by \(store.viewer ?? "you") — click to show everyone's"
                        : "Showing all PRs — click to show only yours")
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help(
                    store.lastRefresh.map { "Last refreshed \($0.formatted(.relative(presentation: .named)))" }
                        ?? "Refresh")
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var newRepo = ""
    @State private var addFailed = false

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(get: { store.filter }, set: { store.filter = $0 ?? .all })) {
            Section("Inbox") {
                row("Everything", "tray.2", store.inboxItems.count).tag(SidebarFilter.all)
                if let at = store.lastDigestAt, !store.lastDigestItemIDs.isEmpty {
                    row(
                        "New at \(at.formatted(date: .omitted, time: .shortened))", "bell.badge",
                        store.activeItems.filter { store.lastDigestItemIDs.contains($0.id) }.count
                    )
                    .tag(SidebarFilter.lastDigest)
                }
                ForEach(AttentionKind.allCases, id: \.self) { k in
                    row(k.title, k.symbol, store.count(k)).tag(SidebarFilter.kind(k))
                }
            }
            Section("GitHub") {
                ForEach(store.repos) { r in
                    row(r.fullName, "book.closed", store.count(repo: r.id))
                        .tag(SidebarFilter.repo(r.id))
                        .contextMenu {
                            Button("Open Pull Requests on GitHub") { openURL(r.pullsURL) }
                            Button("Open Repository on GitHub") { openURL(r.url) }
                            Divider()
                            Button("Set local checkout…") { store.chooseCheckout(for: r) }
                            if let p = store.checkoutPaths[r.id] {
                                Text("Checkout: \((p as NSString).abbreviatingWithTildeInPath)")
                            }
                            Divider()
                            Button("Stop watching", role: .destructive) { store.removeRepo(r) }
                        }
                }
                TextField("owner/repo", text: $newRepo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addFailed = !store.addRepo(newRepo)
                        if !addFailed { newRepo = "" }
                    }
                    .foregroundStyle(addFailed ? .red : .primary)
            }
            if !store.gitlabHost.isEmpty {
                // Projects come and go with your merge requests; there's nothing to add or stop watching.
                Section("GitLab") {
                    row("Mentioned", "at", store.activeMentions.count).tag(SidebarFilter.gitlabMentions)
                    ForEach(store.gitlabProjects) { r in
                        // Group paths are long and shared (`org/team/…`), so the name is what tells them apart.
                        row(r.name, "book.closed", store.count(repo: r.id))
                            .tag(SidebarFilter.repo(r.id))
                            .help(r.fullName)
                            .contextMenu {
                                Button("Open Merge Requests on GitLab") { openURL(r.pullsURL) }
                                Button("Open Project on GitLab") { openURL(r.url) }
                            }
                    }
                    if store.gitlabProjects.isEmpty {
                        Text("No merge requests for you").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if store.linearEnabled {
                Section("Linear") {
                    ForEach(LinearPing.Kind.allCases, id: \.self) { k in
                        row(k.title, k.symbol, store.count(k)).tag(SidebarFilter.linear(k))
                    }
                }
            }
            let errors = store.errors + store.linear.errors
            if !errors.isEmpty {
                Section("Errors") {
                    ForEach(errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                }
            }
            let warnings = store.warnings + store.linear.warnings
            if !warnings.isEmpty {
                Section("Partial data") {
                    ForEach(warnings, id: \.self) {
                        // Sidebar rows truncate to one line; these are sentences, so let them wrap.
                        Text($0).font(.caption).foregroundStyle(.orange).lineLimit(3).help($0)
                    }
                }
            }
            if !store.dismissed.isEmpty || !store.snoozed.isEmpty {
                Button("Show \(store.dismissed.count + store.snoozed.count) hidden") { store.restoreHidden() }
                    .buttonStyle(.link)
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}

struct InboxList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var store = store
        Group {
            if case .linear(let kind) = store.filter {
                PingList(kind: kind)
            } else if store.filter == .gitlabMentions {
                MentionList()
            } else if store.visibleItems.isEmpty, let repo = selectedRepo {
                EmptyState(
                    "Inbox zero", systemImage: "checkmark.circle",
                    description: "Nothing in \(repo.fullName) needs you right now."
                ) {
                    Button("Open \(repo.forge.pullRequestsName.lowercased())") { openURL(repo.pullsURL) }
                        .buttonStyle(.borderedProminent)
                    Button("Repository") { openURL(repo.url) }
                }
            } else if store.visibleItems.isEmpty {
                EmptyState(
                    store.prs.isEmpty ? "No open PRs yet" : "Inbox zero", systemImage: "checkmark.circle",
                    description: store.prs.isEmpty ? "Add a repo to watch." : "Nothing here needs you right now.")
            } else {
                List(selection: $store.selection) {
                    ForEach(store.groupedVisible, id: \.pr.id) { group in
                        Section {
                            ForEach(group.items) { ItemRow(item: $0).tag($0.id) }
                        } header: {
                            PRHeader(
                                pr: group.pr, stats: store.stats[group.pr.id],
                                isMine: group.pr.author == store.viewer(for: group.pr.repo.forge))
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The empty state has its own buttons; this bar is for a list that fills the column.
            if let repo = selectedRepo, !store.visibleItems.isEmpty { RepoLinks(repo: repo) }
        }
    }

    private var selectedRepo: RepoRef? {
        guard case .repo(let id) = store.filter else { return nil }
        return (store.repos + store.gitlabProjects).first { $0.id == id }
    }
}

/// Like ContentUnavailableView, with the icon closer to the title.
struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    @ViewBuilder let actions: Actions

    init(
        _ title: String, systemImage: String, description: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
            Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if Actions.self != EmptyView.self { HStack { actions }.fixedSize().padding(.top, 8) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Under a repo's list, so the repo is one click away even when nothing in it needs you.
struct RepoLinks: View {
    @Environment(\.openURL) private var openURL
    let repo: RepoRef

    var body: some View {
        HStack {
            Button {
                openURL(repo.pullsURL)
            } label: {
                Label(repo.forge.pullRequestsName, systemImage: "arrow.triangle.pull")
            }
            Button {
                openURL(repo.url)
            } label: {
                Label("Repository", systemImage: "book.closed")
            }
            Spacer()
        }
        .help("Open \(repo.fullName) on \(repo.forge.name)")
        .padding(10)
        .background(.bar)
    }
}

struct PRHeader: View {
    let pr: PullRequest
    let stats: PRStats?
    let isMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: "\(pr.repo.name) \(pr.ref)").font(.caption.monospaced())
                if pr.isDraft {
                    Text("draft").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                }
                Spacer()
                if let s = stats, s.pendingChecks > 0 {
                    Label("\(s.pendingChecks)", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                }
                if let s = stats, s.noiseComments > 0 {
                    Label("\(s.noiseComments)", systemImage: "speaker.slash").font(.caption2).foregroundStyle(
                        .secondary)
                }
            }
            Text(pr.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: 5) {
                AsyncImage(url: pr.authorAvatar) {
                    $0.resizable()
                } placeholder: {
                    Color.secondary.opacity(0.3)
                }
                .frame(width: 16, height: 16)
                .clipShape(Circle())
                Text(verbatim: pr.author)
                    .font(.caption)
                    .foregroundStyle(isMine ? Color.accentColor : .secondary)
                    .fontWeight(isMine ? .semibold : .regular)
                if isMine {
                    Text("you").font(.caption2).padding(.horizontal, 5).background(
                        Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ItemRow: View {
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.severity.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind.title).font(.caption).foregroundStyle(.secondary)
                Text(item.headline).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .yellow
        case .info: .green
        }
    }
}
