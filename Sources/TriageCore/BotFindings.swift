import Foundation

extension [AttentionItem] {
    /// Bot findings on your own PRs first, then the others', each newest opened first: the same order as
    /// Everything, `sortedMineFirst(viewer:)`.
    public func sortedAsBotFindings(viewer: (Forge) -> String?) -> [AttentionItem] {
        sortedMineFirst(viewer: viewer)
    }
}

extension AttentionItem {
    /// Explain & propose fix, Fix in iTerm and Copy prompt are for your own code: a bot finding on someone
    /// else's PR leaves them out, since you can't push to their branch. While `viewer` is unknown they stay.
    public func showsFixActions(viewer: String?) -> Bool {
        guard kind == .botFinding, let viewer else { return true }
        return pr.author == viewer
    }
}
