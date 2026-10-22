import SwiftUI
import TriageCore

/// Merge's entries in the Open menu and the Pull Request menu: one per method the repo allows, the default first,
/// each asking to confirm in the item detail. The merge note heads them: when the forge would refuse it's the
/// reason and they're disabled, otherwise a caution ("Approval required") that leaves them enabled. ⇧⌘M (bound in
/// the menu bar only) uses the default method.
struct MergeMenuItems: View {
    let pr: PullRequest
    let inMenuBar: Bool
    let confirm: (MergeMethod) -> Void

    var body: some View {
        let blocker = pr.mergeBlocker
        // A menu shows Text as a disabled item: the note, right above the entries it's about.
        if let note = pr.mergeNote { Text(note) }
        ForEach(methods, id: \.self) { method in
            Button("\(method.title(on: pr.repo.forge))…") { confirm(method) }
                .shortcut("m", modifiers: [.command, .shift], if: inMenuBar && method == pr.defaultMergeMethod)
                .disabled(blocker != nil)
        }
    }

    /// The default first, then the others in the forge's order.
    private var methods: [MergeMethod] {
        [pr.defaultMergeMethod] + pr.mergeMethods.filter { $0 != pr.defaultMergeMethod }
    }
}
