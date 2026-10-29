extension [AttentionItem] {
    /// A kind's own list: Review requested has its review order; every other kind keeps the order it came in.
    public func orderedForList(of kind: AttentionKind) -> [AttentionItem] {
        kind == .reviewRequested ? sortedForReview() : self
    }

    /// The Review requested inbox, in the order a reviewer should take it:
    /// 1. PRs that are ready before drafts, since a draft isn't asking for a review yet.
    /// 2. PRs whose checks aren't failing before those that are, since the author is likely to push again.
    /// 3. The longest-open PR first, so nobody's request waits behind newer ones.
    /// Ties fall to the repo, then the number, then the item id, so the order depends only on the data and not on
    /// the order it arrived in, and a refresh of unchanged PRs doesn't shuffle them.
    public func sortedForReview() -> [AttentionItem] {
        sorted { a, b in
            let (x, y) = (a.pr, b.pr)
            if x.isDraft != y.isDraft { return !x.isDraft }
            let (xFails, yFails) = (
                x.checks.contains { $0.state == .failure }, y.checks.contains { $0.state == .failure }
            )
            if xFails != yFails { return !xFails }
            if x.createdAt != y.createdAt { return x.createdAt < y.createdAt }
            if x.repo.id != y.repo.id { return x.repo.id < y.repo.id }
            if x.number != y.number { return x.number < y.number }
            return a.id < b.id
        }
    }
}
