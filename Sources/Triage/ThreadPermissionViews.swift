import SwiftUI
import TriageCore

struct ThreadPermissionView: View {
    @Environment(ThreadStore.self) private var store
    let permission: WorkbenchPermission
    let threadID: UUID

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    permission.description.isEmpty ? "Claude wants to use \(permission.tool)." : permission.description
                ).font(.callout)
                Text(permission.tool).font(.caption.monospaced()).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(permission.input.formatted).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
                HStack {
                    Button("Deny") { Task { await store.answer(permission, in: threadID, allow: false) } }
                    Spacer()
                    if let rules = store.rulesToRemember(for: permission, in: threadID) {
                        Menu("Always allow") {
                            Button("In this thread") { remember(.thread) }
                            Button("In this project") { remember(.project) }
                            Button("In this project and its repository settings") { remember(.repository) }
                        }
                        .menuStyle(.button).fixedSize()
                        .help("Allow \(rules.joined(separator: ", ")) without asking")
                    }
                    Button("Allow once") { Task { await store.answer(permission, in: threadID, allow: true) } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Permission needed", systemImage: "hand.raised")
        }
    }

    private func remember(_ scope: RuleScope) {
        Task { await store.answer(permission, in: threadID, allow: true, remember: scope) }
    }
}

struct ProjectPermissionsSheet: View {
    @Environment(ThreadStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    var threadID: UUID?

    private var project: WorkbenchProject? { store.projects.first { $0.id == projectID } }
    private var thread: WorkbenchThread? { store.threads.first { $0.id == threadID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let project {
                Text("Permissions for \(project.name)").font(.title2.weight(.semibold))
                Picker(
                    "Run without asking",
                    selection: Binding(get: { project.preset }, set: { store.setPreset($0, for: projectID) })
                ) {
                    ForEach(PermissionPreset.allCases) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }.tag(preset)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Destructive commands, commands that touch paths outside the worktree and merges always ask.")
                    .font(.caption).foregroundStyle(.secondary)
                ruleList(title: "Saved for this project", rules: project.rules) {
                    store.removeRule($0, from: projectID)
                }
                if let thread, !thread.rules.isEmpty {
                    ruleList(title: "Saved for this thread", rules: thread.rules) {
                        store.removeRule($0, fromThread: thread.id)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }

    @ViewBuilder
    private func ruleList(title: String, rules: [String], remove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if rules.isEmpty {
                Text("None yet. Choose Always allow on a permission prompt.").font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules, id: \.self) { rule in
                    HStack {
                        Text(rule).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            remove(rule)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain).help("Remove this rule").accessibilityLabel("Remove \(rule)")
                    }
                }
            }
        }
    }
}
