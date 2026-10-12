import Foundation

public struct WorkbenchProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public enum WorkbenchState: String, Codable, Sendable {
    case queued, starting, running, waitingPermission, idle, interrupted, failed

    public var isBusy: Bool { [.queued, .starting, .running, .waitingPermission].contains(self) }
    public var title: String {
        switch self {
        case .queued: "Queued"
        case .starting: "Starting"
        case .running: "Running"
        case .waitingPermission: "Needs permission"
        case .idle: "Ready"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        }
    }
}

public struct WorkbenchMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, assistant, step, error }
    public let id: UUID
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public struct WorkbenchThread: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let sessionID: UUID
    public let title: String
    public let worktree: String
    public let branch: String
    public var state: WorkbenchState
    public var hasSession: Bool
    public let model: String?
    public var messages: [WorkbenchMessage]

    public init(
        id: UUID = UUID(), projectID: UUID, sessionID: UUID = UUID(), title: String,
        worktree: String, branch: String, state: WorkbenchState = .idle, hasSession: Bool = false,
        messages: [WorkbenchMessage] = [], model: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.sessionID = sessionID
        self.title = title
        self.worktree = worktree
        self.branch = branch
        self.state = state
        self.hasSession = hasSession
        self.model = model
        self.messages = messages
    }
}

public struct WorkbenchCatalog: Codable, Equatable, Sendable {
    public var projects: [WorkbenchProject]
    public var threads: [WorkbenchThread]

    public init(projects: [WorkbenchProject] = [], threads: [WorkbenchThread] = []) {
        self.projects = projects
        self.threads = threads
    }

    public func recovered() -> Self {
        var copy = self
        for index in copy.threads.indices where copy.threads[index].state.isBusy {
            copy.threads[index].state = .interrupted
        }
        return copy
    }
}

public struct WorkbenchError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum WorkbenchWorktree {
    public static func project(at url: URL) async throws -> WorkbenchProject {
        let root = try await git(url.path, ["rev-parse", "--show-toplevel"])
        return WorkbenchProject(name: URL(fileURLWithPath: root).lastPathComponent, path: root)
    }

    public static func create(
        project: WorkbenchProject, id: UUID = UUID(), title: String = "New thread", model: String? = nil
    ) async throws -> WorkbenchThread {
        let root = URL(fileURLWithPath: project.path)
        let slug = "workbench-" + id.uuidString.lowercased()
        let ignored = try await Subprocess.run(
            "/usr/bin/git", ["-C", root.path, "check-ignore", "-q", ".claude/worktrees/\(slug)"])
        let directory =
            ignored.status == 0
            ? root.appendingPathComponent(".claude/worktrees")
            : root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-worktrees")
        let worktree = directory.appendingPathComponent(slug)
        var base = "HEAD"
        for candidate in ["origin/HEAD", "origin/main", "origin/master"] {
            let found = try await Subprocess.run(
                "/usr/bin/git", ["-C", root.path, "rev-parse", "--verify", "\(candidate)^{commit}"])
            if found.status == 0 { base = candidate; break }
        }
        _ = try await git(root.path, ["worktree", "add", "-b", slug, worktree.path, base])
        return WorkbenchThread(
            id: id, projectID: project.id, title: title, worktree: worktree.path, branch: slug, model: model)
    }

    private static func git(_ path: String, _ arguments: [String]) async throws -> String {
        let output = try await Subprocess.run("/usr/bin/git", ["-C", path] + arguments)
        guard output.status == 0 else {
            throw WorkbenchError(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.trimmedStdout
    }
}
