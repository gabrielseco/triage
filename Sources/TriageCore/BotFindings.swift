import Foundation

extension [AttentionItem] {
    /// Bot findings on your own PRs first, then the others', each newest opened first. `viewer` says who you
    /// are on a forge; while it's unknown nothing counts as yours. Items of one PR keep their order.
    public func sortedAsBotFindings(viewer: (Forge) -> String?) -> [AttentionItem] {
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
