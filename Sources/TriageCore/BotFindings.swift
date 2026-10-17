import Foundation

extension [AttentionItem] {
    /// Bot findings in `sortedMineFirst` order.
    public func sortedAsBotFindings(viewer: (Forge) -> String?) -> [AttentionItem] {
        sortedMineFirst(viewer: viewer)
    }

    /// Items on your own PRs first, then the others', each newest opened first, ties by number highest first.
    /// `viewer` says who you are on a forge; while it's unknown nothing counts as yours. Items of one PR keep
    /// their order. Everything and the Bot finding filter both list in this order.
    public func sortedMineFirst(viewer: (Forge) -> String?) -> [AttentionItem] {
        let keyed = enumerated().map { offset, item in
            (item: item, mine: item.pr.author == viewer(item.pr.repo.forge), offset: offset)
        }
        return keyed.sorted { a, b in
            if a.mine != b.mine { return a.mine }
            let (ka, kb) = ((a.item.pr.createdAt, a.item.pr.number), (b.item.pr.createdAt, b.item.pr.number))
            return ka != kb ? ka > kb : a.offset < b.offset
        }
        .map(\.item)
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
