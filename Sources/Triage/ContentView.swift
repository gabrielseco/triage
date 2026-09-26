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
            } else {
                ContentUnavailableView(
                    "Nothing selected", systemImage: "tray",
                    description: Text(
                        store.repos.isEmpty
                            ? "Add a repo in the sidebar to start watching." : "Pick an item from the inbox."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(store.summaryLine).font(.callout).foregroundStyle(.secondary)
            }
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
    @State private var newRepo = ""
    @State private var addFailed = false

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(get: { store.filter }, set: { store.filter = $0 ?? .all })) {
            Section("Inbox") {
                row("Everything", "tray.2", store.activeItems.count).tag(SidebarFilter.all)
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
            Section("Watching") {
                ForEach(store.repos) { r in
                    row(r.fullName, "book.closed", store.count(repo: r.fullName))
                        .tag(SidebarFilter.repo(r.fullName))
                        .contextMenu {
                            Button("Set local checkout…") { store.chooseCheckout(for: r) }
                            if let p = store.checkoutPaths[r.fullName] {
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
            if !store.errors.isEmpty {
                Section("Errors") {
                    ForEach(store.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
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

    var body: some View {
        @Bindable var store = store
        Group {
            if store.visibleItems.isEmpty {
                ContentUnavailableView(
                    store.prs.isEmpty ? "No open PRs yet" : "Inbox zero",
                    systemImage: "checkmark.circle",
                    description: Text(store.prs.isEmpty ? "Add a repo to watch." : "Nothing here needs you right now."))
            } else {
                List(selection: $store.selection) {
                    ForEach(store.groupedVisible, id: \.pr.id) { group in
                        Section {
                            ForEach(group.items) { ItemRow(item: $0).tag($0.id) }
                        } header: {
                            PRHeader(
                                pr: group.pr, stats: store.stats[group.pr.id], isMine: group.pr.author == store.viewer)
                        }
                    }
                }
            }
        }
    }
}

struct PRHeader: View {
    let pr: PullRequest
    let stats: PRStats?
    let isMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: "\(pr.repo.name) #\(pr.number)").font(.caption.monospaced())
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
