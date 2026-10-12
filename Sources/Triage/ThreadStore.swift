import Foundation
import Observation
import TriageCore

@MainActor @Observable
final class ThreadStore {
    var projects: [WorkbenchProject] = []
    var threads: [WorkbenchThread] = []
    var selection: UUID?
    var error: String?
    var isAddingProject = false
    var isCreating = false
    var isLoading = true
    var model = ""
    var permissions: [UUID: [WorkbenchPermission]] = [:]
    var streamingText: [UUID: String] = [:]
    var rawOutput: [UUID: String] = [:]
    private let supervisor: ThreadSupervisor
    private let storage: WorkbenchStorage
    private let logs: URL
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var persistenceAvailable = true

    var selectedThread: WorkbenchThread? { threads.first { $0.id == selection } }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let arguments = ProcessInfo.processInfo.arguments
        let override = arguments.firstIndex(of: "--workbench-data-directory").flatMap { index in
            arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil
        }
        logs = override?.appendingPathComponent("logs") ?? home.appendingPathComponent("Library/Logs/Triage/threads")
        storage = WorkbenchStorage(
            directory: override ?? home.appendingPathComponent("Library/Application Support/Triage/threads"))
        var environment = ProcessInfo.processInfo.environment
        let search = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] =
            search.joined(separator: ":") + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        supervisor = ThreadSupervisor(environment: environment, logDirectory: logs)
        loadTask = Task { await load() }
        Task {
            for await update in supervisor.events { consume(update) }
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            let catalog = try await storage.load()
            projects = catalog.projects
            threads = catalog.threads
            selection = threads.first?.id
        } catch {
            persistenceAvailable = false
            self.error = "Could not load threads: \(error.localizedDescription)"
        }
    }

    func addProject(_ url: URL) async {
        guard !isAddingProject, !isLoading, persistenceAvailable else { return }
        isAddingProject = true
        defer { isAddingProject = false }
        do {
            let project = try await WorkbenchWorktree.project(at: url)
            if !projects.contains(where: { $0.path == project.path }) { projects.append(project) }
            error = nil
            persist()
        } catch { self.error = "Could not add project: \(error.localizedDescription)" }
    }

    func createThread(projectID: UUID, prompt: String) async {
        guard !isCreating, !isLoading, persistenceAvailable,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let project = projects.first(where: { $0.id == projectID })
        else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let title = String((prompt.split(separator: "\n").first.map(String.init) ?? prompt).prefix(100))
            let thread = try await WorkbenchWorktree.create(
                project: project, title: title, model: model.isEmpty ? nil : model)
            threads.insert(thread, at: 0)
            selection = thread.id
            await send(prompt, to: thread.id)
        } catch { self.error = "Could not create thread: \(error.localizedDescription)" }
    }

    func send(_ prompt: String, to id: UUID) async {
        guard let index = threads.firstIndex(where: { $0.id == id }), !threads[index].state.isBusy,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        error = nil
        threads[index].messages.append(.init(kind: .user, text: prompt))
        threads[index].state = .queued
        streamingText[id] = ""
        persist()
        do { try await supervisor.submit(threads[index], prompt: prompt) } catch {
            if let current = threads.firstIndex(where: { $0.id == id }) {
                threads[current].state = .failed
                threads[current].messages.append(.init(kind: .error, text: error.localizedDescription))
                persist()
            }
        }
    }

    func stop(_ id: UUID) async { await supervisor.stop(id) }

    func answer(_ permission: WorkbenchPermission, in id: UUID, allow: Bool) async {
        do { try await supervisor.answer(permission, threadID: id, allow: allow) } catch {
            self.error = error.localizedDescription
        }
    }

    func loadRaw(_ id: UUID) async {
        guard rawOutput[id] == nil else { return }
        let directory = logs
        do {
            let text = try await Task.detached { try WorkbenchStorage.raw(at: directory, id: id) }.value
            if rawOutput[id] == nil { rawOutput[id] = text }
        } catch { self.error = "Could not load output: \(error.localizedDescription)" }
    }

    func shutdown() async {
        await loadTask?.value
        await supervisor.shutdown()
        for index in threads.indices where threads[index].state.isBusy { threads[index].state = .interrupted }
        saveTask?.cancel()
        guard persistenceAvailable else { return }
        do { try await storage.save(WorkbenchCatalog(projects: projects, threads: threads)) } catch {
            self.error = "Could not save threads: \(error.localizedDescription)"
        }
    }

    private func consume(_ update: WorkbenchUpdate) {
        switch update {
        case .state(let id, let state):
            if let index = threads.firstIndex(where: { $0.id == id }) { threads[index].state = state }
            if !state.isBusy { permissions[id] = []; streamingText[id] = "" }
        case .message(let id, let message):
            addMessage(message, to: id)
        case .partial(let id, let text):
            streamingText[id] = String(((streamingText[id] ?? "") + text).suffix(32_000))
            return
        case .permission(let id, let permission):
            addPermission(permission, to: id)
        case .cancelPermission(let id, let request): permissions[id]?.removeAll { $0.id == request }
        case .raw(let id, let text):
            rawOutput[id] = String(((rawOutput[id] ?? "") + text).suffix(256_000))
            return
        case .session(let id):
            if let index = threads.firstIndex(where: { $0.id == id }) { threads[index].hasSession = true }
        }
        persist()
    }

    private func addMessage(_ message: WorkbenchMessage, to id: UUID) {
        if let index = threads.firstIndex(where: { $0.id == id }) {
            threads[index].messages.append(message)
            threads[index].messages = Array(threads[index].messages.suffix(200))
        }
        if message.kind == .assistant { streamingText[id] = "" }
    }

    private func addPermission(_ permission: WorkbenchPermission, to id: UUID) {
        if !(permissions[id] ?? []).contains(where: { $0.id == permission.id }) {
            permissions[id, default: []].append(permission)
        }
    }

    private func persist() {
        let catalog = WorkbenchCatalog(projects: projects, threads: threads)
        saveTask?.cancel()
        saveTask = Task {
            do { try await storage.save(catalog) } catch is CancellationError {} catch {
                self.error = "Could not save threads: \(error.localizedDescription)"
            }
        }
    }
}
