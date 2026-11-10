import SwiftUI
import TriageCore

/// Under a review thread: Explain, then the reasoning and proposed fix with Fix and False positive, and a separate
/// Resolve. Fix is never run for you and nothing resolves a thread but its own button.
struct ThreadActionsView: View {
    @Environment(AppStore.self) private var store
    let threadID: String
    let state: ThreadState
    let item: AttentionItem

    private var explanation: ThreadExplanationStatus { store.threadExplanation(threadID, in: item) }
    private var busy: Bool { store.threadBusy.contains(threadID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = explanation.explanation { explanationBlock(e) }
            if !isResolved { buttons }
            if let message = store.threadStatus[threadID] {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.top, 2)
    }

    private var isResolved: Bool {
        if case .resolved = state { true } else { false }
    }

    private var isStale: Bool {
        if case .stale = explanation { true } else { false }
    }

    private func explanationBlock(_ e: ThreadExplanation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isStale {
                Label("Written for an older commit — explain again", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Reasoning").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(e.reasoning).font(.callout).textSelection(.enabled)
            Text("Proposed fix").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(e.proposedFix).font(.callout).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            if explanation.explanation == nil || isStale {
                Button("Explain") { Task { await store.explainThread(threadID, in: item) } }
                    .help("Have Workbench explain this thread and propose a fix")
            }
            if explanation.explanation != nil, state == .open {
                Button("Fix") { Task { await store.fixThread(threadID, in: item) } }
                    .buttonStyle(.borderedProminent)
                    .help("Have Workbench apply the fix, push it and reply with the commit on this thread")
            }
            if state == .open, explanation.explanation != nil {
                Button("False positive") { store.dismissThreadAsFalsePositive(threadID) }
                    .help("Dismiss this thread here only; it stays open on \(item.pr.repo.forge.name)")
            }
            if state == .falsePositive {
                Button("Undo") { store.restoreThread(threadID) }
            }
            Spacer()
            Button("Resolve") { Task { await store.resolveThread(threadID, in: item) } }
                .help("Resolve this thread on \(item.pr.repo.forge.name)")
        }
        .controlSize(.small)
        .disabled(busy)
    }
}
