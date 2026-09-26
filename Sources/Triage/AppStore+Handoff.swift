import AppKit
import Foundation
import TriageCore

/// Fix in iTerm: hand an item to a coding agent in a per-PR git worktree.
extension AppStore {
    // MARK: - Fix in iTerm

    static let checkoutRoots = ["~/remote", "~/rogal", "~/code", "~/src", "~/dev", "~/projects", "~/Developer", "~"]
        .map { ($0 as NSString).expandingTildeInPath }

    /// Remembered path, else auto-detected (`<root>/<repo name>` whose origin is this repo) and remembered.
    func checkoutPath(for repo: RepoRef) async -> String? {
        if let p = checkoutPaths[repo.fullName], FileManager.default.fileExists(atPath: p) { return p }
        guard let found = await Handoff.findCheckout(repo, roots: Self.checkoutRoots) else { return nil }
        checkoutPaths[repo.fullName] = found
        return found
    }

    /// Asks for the local clone with a folder picker; returns nil if cancelled or not a clone of `repo`.
    @discardableResult
    func chooseCheckout(for repo: RepoRef) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your local clone of \(repo.fullName)"
        panel.prompt = "Use this checkout"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        checkoutPaths[repo.fullName] = url.path
        return url.path
    }

    func fixInTerminal(_ item: AttentionItem) async {
        let repo = item.pr.repo
        guard let checkout = await checkoutPath(for: repo) ?? chooseCheckout(for: repo) else {
            actionStatus[item.id] =
                "No local checkout of \(repo.fullName) — right-click the repo in the sidebar to set one."
            return
        }
        actionStatus[item.id] = "Fetching logs and diff…"
        let prompt = await buildPrompt(for: item, mode: .handoff)
        do {
            // Caches, not Application Support: iTerm's `command` splits on spaces.
            let dir = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            .appendingPathComponent("dev.rogal.triage/handoffs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = "\(repo.owner)-\(repo.name)-\(item.pr.number)-\(item.kind.rawValue)"
            let promptURL = dir.appendingPathComponent("\(base).md")
            let scriptURL = dir.appendingPathComponent("\(base).command")
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
            let plan = HandoffPlan(
                repo: repo, prNumber: item.pr.number, branch: item.pr.headRef, checkout: checkout,
                promptFile: promptURL.path, harnessCommand: harnessCommand)
            try Handoff.script(plan).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            try await ITerm.open(runningScript: scriptURL.path)
            actionStatus[item.id] = "Opened iTerm in \((plan.worktree as NSString).abbreviatingWithTildeInPath)"
        } catch {
            actionStatus[item.id] = "Couldn't hand off: \(error.localizedDescription)"
        }
    }
}
