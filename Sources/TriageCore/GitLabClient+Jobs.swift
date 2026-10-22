import Foundation

extension MRNode.Job {
    /// Job and pipeline statuses share these values. Nil when there's no status.
    static func state(_ status: String?) -> CheckState? {
        switch status {
        case nil: nil
        case "SUCCESS": .success
        case "FAILED": .failure
        case "CREATED", "WAITING_FOR_RESOURCE", "PREPARING", "PENDING", "RUNNING", "SCHEDULED",
            "WAITING_FOR_CALLBACK":
            .pending
        default: .neutral  // CANCELED, CANCELING, SKIPPED, MANUAL
        }
    }

    func model(_ hostURL: URL) -> CheckInfo {
        var state = Self.state(status) ?? .neutral
        if state == .failure, allowFailure == true { state = .neutral }
        // "gid://gitlab/Ci::Build/123": the number is the job id, for its log.
        let jobID = id.split(separator: "/").last.flatMap { Int($0) }
        return CheckInfo(
            name: name ?? "job", state: state,
            url: webPath.flatMap { URL(string: $0, relativeTo: hostURL)?.absoluteURL }, checkRunID: jobID)
    }
}

extension MRNode.Note {
    /// The URL is what item ids are built from, so a note without one gets its anchor on the MR
    /// (`#note_<id>`), never nil: a nil URL would keep a dismissed item hidden after a new reply.
    func model(_ hostURL: URL, mr: URL) -> CommentInfo {
        let anchor = id.split(separator: "/").last.flatMap { URL(string: "\(mr.absoluteString)#note_\($0)") }
        return CommentInfo(
            author: author?.login ?? "ghost", isBot: author?.isBot ?? false, body: body,
            url: url.flatMap { URL(string: $0, relativeTo: hostURL)?.absoluteURL } ?? anchor, createdAt: createdAt)
    }
}
