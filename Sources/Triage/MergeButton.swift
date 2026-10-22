import SwiftUI
import TriageCore

/// GitHub's merge box: Merge uses the default method, the Merge method menu picks one for this merge. Both ask to
/// confirm in the item detail. Disabled when the forge would refuse; `MergeNote` says why, on the line below the row.
struct MergeButton: View {
    @Environment(AppStore.self) private var store
    let item: AttentionItem

    var body: some View {
        let pr = item.pr
        let blocker = pr.mergeBlocker
        HStack(spacing: 2) {
            Button {
                confirm(pr.defaultMergeMethod)
            } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
            }
            .help(
                blocker.map { "Can't merge: \($0.lowercased())" }
                    ?? "\(pr.defaultMergeMethod.title(on: pr.repo.forge)) on \(pr.repo.forge.name) (⇧⌘M)")
            Menu {
                ForEach(pr.mergeMethods, id: \.self) { method in
                    // Checked is the default, what Merge uses; picking one asks to confirm a merge with it.
                    Toggle(
                        method.title(on: pr.repo.forge),
                        isOn: Binding(get: { method == pr.defaultMergeMethod }, set: { _ in confirm(method) }))
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Merge method")
            .help("Merge method: pick one for this merge")
        }
        .prominent(item.kind == .readyToMerge)
        .fixedSize()
        .disabled(blocker != nil)
    }

    private func confirm(_ method: MergeMethod) {
        store.confirming = PRConfirmation(action: .merge(method), item: item)
    }
}

/// Why Merge is disabled, or failing checks and missing reviews that don't stop it. On its own line, so the
/// action row keeps every button readable at the minimum width.
struct MergeNote: View {
    let pr: PullRequest

    var body: some View {
        if let note = pr.mergeNote {
            let blocks = pr.mergeBlocker != nil
            Label(note, systemImage: blocks ? "nosign" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(blocks ? "Can't merge yet" : "Merging is allowed anyway")
        }
    }
}

extension View {
    /// A control drawn as the state's `.borderedProminent` primary action, or left as is.
    @ViewBuilder func prominent(_ isPrimary: Bool) -> some View {
        if isPrimary { menuStyle(.button).buttonStyle(.borderedProminent) } else { self }
    }
}
