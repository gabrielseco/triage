import Foundation

extension [AttentionItem] {
    /// Items on your own PRs first, then the others', each newest opened first, ties by PR number highest first.
    /// `viewer` says who you are on a forge; while it's unknown nothing counts as yours. Items of one PR keep their
    /// order. Everything and Bot finding both list in this order.
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
