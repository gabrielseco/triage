import AppKit
import SwiftUI
import TriageCore

struct ThreadsView: View {
    @Environment(ThreadStore.self) private var store
    @State private var showingNewThread = false
    @State private var permissionsProjectID: UUID?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.projects) { project in
                    Section {
                        ForEach(store.threads.filter { $0.projectID == project.id }) { thread in
                            ThreadRow(thread: thread, project: project).tag(thread.id)
                        }
                        if !store.threads.contains(where: { $0.projectID == project.id }) {
                            Text("No threads yet").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } header: {
                        HStack {
                            Text(project.name)
                            Spacer()
                            Button {
                                permissionsProjectID = project.id
                            } label: {
                                Image(systemName: "checkmark.shield")
                            }
                            .buttonStyle(.plain)
                            .help("\(project.preset.title): choose what runs without asking")
                            .accessibilityLabel("Permissions for \(project.name)")
                        }
                    }
                }
            }
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects", systemImage: "folder",
                        description: Text("Add a local repository to start a thread."))
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = store.error, !showingNewThread {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Button {
                        chooseThreadProject(store)
                    } label: {
                        if store.isAddingProject {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Add project…", systemImage: "folder.badge.plus")
                        }
                    }
                    .disabled(store.isAddingProject)
                    .help("Choose a local Git repository")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.bar)
            }
        } detail: {
            if let thread = store.selectedThread {
                ThreadDetailView(thread: thread).id(thread.id)
            } else {
                ContentUnavailableView(
                    "No thread selected", systemImage: "text.bubble",
                    description: Text("Choose a thread or start a new one."))
            }
        }
        .navigationTitle("Threads")
        .toolbar {
            Button {
                showingNewThread = true
            } label: {
                Label("New thread", systemImage: "square.and.pencil")
            }
            .help("Start a thread in its own worktree")
        }
        .sheet(isPresented: $showingNewThread) {
            NewThreadSheet().environment(store)
        }
        .sheet(
            isPresented: Binding(
                get: { permissionsProjectID != nil }, set: { if !$0 { permissionsProjectID = nil } })
        ) {
            if let id = permissionsProjectID { ProjectPermissionsSheet(projectID: id).environment(store) }
        }
    }
}

struct ThreadRow: View {
    let thread: WorkbenchThread
    let project: WorkbenchProject

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: thread.state.symbol).foregroundStyle(thread.state.color).frame(width: 18)
                .help(thread.state.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(2).help(thread.title)
                Text(thread.state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(project.path)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NewThreadSheet: View {
    @Environment(ThreadStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var prompt = ""

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Text("New thread").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Picker("Project", selection: $projectID) {
                    Text("Choose a project").tag(nil as UUID?)
                    ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Button {
                    chooseThreadProject(store)
                } label: {
                    if store.isAddingProject { ProgressView().controlSize(.small) } else { Text("Browse…") }
                }
                .disabled(store.isAddingProject || store.isCreating)
                .help("Add a local Git repository")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What would you like to work on?").font(.headline)
                TextEditor(text: $prompt).frame(minHeight: 140).padding(4)
                    .border(.quaternary).accessibilityLabel("Thread prompt")
            }
            Picker("Model", selection: $store.model) {
                Text("Default").tag("")
                Text("Haiku").tag("haiku")
                Text("Sonnet").tag("sonnet")
                Text("Opus").tag("opus")
            }
            Picker("Permissions", selection: $store.threadPreset) {
                Text("Project default").tag(nil as PermissionPreset?)
                ForEach(PermissionPreset.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .help("What runs without asking in this thread")
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isCreating)
                Spacer()
                Button {
                    guard let projectID else { return }
                    Task {
                        await store.createThread(projectID: projectID, prompt: prompt)
                        if store.error == nil { dismiss() }
                    }
                } label: {
                    if store.isCreating { ProgressView().controlSize(.small) } else { Text("Start") }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(
                    projectID == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.isCreating)
            }
        }
        .padding(20).frame(width: 520)
        .disabled(store.isCreating)
        .onAppear { projectID = store.projects.first?.id }
        .onChange(of: store.projects.count) { _, _ in projectID = store.projects.last?.id }
    }
}

struct ThreadDetailView: View {
    @Environment(ThreadStore.self) private var store
    let thread: WorkbenchThread
    @State private var prompt = ""
    @State private var showingRaw = false
    @State private var showingPermissions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(thread.messages) { ThreadMessageView(message: $0) }
                        if let text = store.streamingText[thread.id], !text.isEmpty {
                            ThreadMessageView(message: WorkbenchMessage(kind: .assistant, text: text))
                        }
                        if thread.state.isBusy && thread.state != .waitingPermission {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(thread.state.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(store.permissions[thread.id] ?? []) { permission in
                            ThreadPermissionView(permission: permission, threadID: thread.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: thread.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.streamingText[thread.id]) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.permissions[thread.id]?.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if showingRaw {
                GroupBox("Raw output") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(store.rawOutput[thread.id] ?? "Loading…").font(.caption.monospaced()).textSelection(
                            .enabled
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 140)
                }
            }
            composer
        }
        .padding(20)
        .sheet(isPresented: $showingPermissions) {
            ProjectPermissionsSheet(projectID: thread.projectID, threadID: thread.id).environment(store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.title).font(.title2.weight(.semibold)).lineLimit(2).help(thread.title)
            HStack(spacing: 8) {
                Label(thread.state.title, systemImage: thread.state.symbol).font(.callout).foregroundStyle(
                    thread.state.color)
                Spacer()
                Button {
                    showingPermissions = true
                } label: {
                    Label("Permissions", systemImage: "checkmark.shield")
                }
                .help("Choose what runs without asking, and review saved rules")
                Toggle("Raw output", isOn: $showingRaw).toggleStyle(.button).help("Show the thread's diagnostic output")
                    .onChange(of: showingRaw) { _, shown in if shown { Task { await store.loadRaw(thread.id) } } }
                if thread.state.isBusy {
                    Button("Stop") { Task { await store.stop(thread.id) } }.help("Stop this thread")
                }
            }
            HStack(spacing: 6) {
                Text((thread.worktree as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(
                    .secondary
                )
                .lineLimit(1).truncationMode(.middle).help(thread.worktree)
                Button {
                    NSWorkspace.shared.selectFile(thread.worktree, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                }.help("Show worktree in Finder")
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $prompt).frame(height: 80).padding(4).border(.quaternary)
                .accessibilityLabel("Message to thread").disabled(thread.state.isBusy)
            HStack {
                Text(
                    thread.state.isBusy
                        ? "Wait for this turn to finish, or stop it." : "Send a message to continue this thread."
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(thread.state == .interrupted || thread.state == .failed ? "Resume" : "Send") {
                    let message = prompt
                    prompt = ""
                    Task { await store.send(message, to: thread.id) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                .disabled(thread.state.isBusy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct ThreadMessageView: View {
    let message: WorkbenchMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(message.kind == .error ? .red : .secondary)
            Text(message.text).font(message.kind == .step || message.kind == .error ? .callout : .body)
                .foregroundStyle(message.kind == .error ? .red : .primary).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch message.kind {
        case .user: "You"
        case .assistant: "Claude"
        case .step: "Activity"
        case .error: "Error"
        }
    }
}

@MainActor
private func chooseThreadProject(_ store: ThreadStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a local Git repository"
    panel.prompt = "Add project"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await store.addProject(url) }
}

extension WorkbenchState {
    fileprivate var symbol: String {
        switch self {
        case .queued: "clock"
        case .starting, .running: "play.circle"
        case .waitingPermission: "hand.raised"
        case .idle: "checkmark.circle"
        case .interrupted: "stop.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .failed: .red
        case .waitingPermission: .orange
        default: .secondary
        }
    }
}
