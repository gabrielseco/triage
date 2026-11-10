extension PRNode.ThreadNode {
    /// The thread as the app models it, or nil when it has no comments. `comments` is the newest 30, so in a
    /// longer thread the opening comment is only in `opening` and every fetched comment is a reply.
    var info: ReviewThreadInfo? {
        let newest = comments.nodes, firstNode = opening?.nodes.first
        let cut = comments.totalCount > newest.count && firstNode != nil
        guard let first = cut ? firstNode : newest.first else { return nil }
        return ReviewThreadInfo(
            isResolved: isResolved, isOutdated: isOutdated, resolvedBy: resolvedBy?.login, path: path, line: line,
            firstComment: first.model, commentCount: comments.totalCount,
            replies: (cut ? newest : Array(newest.dropFirst())).map(\.model), id: id)
    }
}
