import AppKit
import Foundation
import TriageCore

/// Explain PR through Workbench (docs/plans/EXPLAIN.md).
extension AppStore {
    static let checkoutRoots = ["~/remote", "~/rogal", "~/code", "~/src", "~/dev", "~/projects", "~/Developer", "~"]
        .map { ($0 as NSString).expandingTildeInPath }

    /// Remembered path, else auto-detected (`<root>/<repo name>` whose origin is this repo) and remembered.
    func checkoutPath(for repo: RepoRef) async -> String? {
        if let p = checkoutPaths[repo.id], FileManager.default.fileExists(atPath: p) { return p }
        guard let found = await LocalCheckout.find(repo, roots: Self.checkoutRoots) else { return nil }
        checkoutPaths[repo.id] = found
        return found
    }

    /// Asks for the local clone with a folder picker; returns nil if cancelled.
    @discardableResult
    func chooseCheckout(for repo: RepoRef) -> String? {
        guard !MockMode.isActive else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your local clone of \(repo.fullName)"
        panel.prompt = "Use this checkout"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        checkoutPaths[repo.id] = url.path
        return url.path
    }

    func explainStatus(_ item: AttentionItem) -> ExplainPR.Status {
        ExplainPR.status(
            record: explainRecords[item.pr.id], currentHead: item.pr.headSha, running: explaining.contains(item.pr.id))
    }

    /// Runs `workbench explain-pr` for the PR, keeps the note and opens it. The work happens off the main actor.
    func explainPR(_ item: AttentionItem) async {
        let pr = item.pr
        guard !explaining.contains(pr.id) else { return }
        if MockMode.isActive {
            actionStatus[item.id] = "Mock mode: this would run Workbench on \(pr.ref)."
            return
        }
        guard let workbench = ExplainPR.findWorkbench(setting: workbenchPath) else {
            actionStatus[item.id] = ExplainPR.Failure.workbenchNotFound.localizedDescription
            return
        }
        guard let checkout = await checkoutPath(for: pr.repo) ?? chooseCheckout(for: pr.repo) else {
            actionStatus[item.id] = "No local checkout of \(pr.repo.fullName): right-click the repo in the sidebar."
            return
        }
        explaining.insert(pr.id)
        actionStatus[item.id] = "Workbench is explaining \(pr.ref)… this can take a few minutes."
        defer { explaining.remove(pr.id) }
        do {
            let out = try await ExplainPR.run(
                ExplainPR.Job(
                    workbench: workbench, checkout: checkout, repo: pr.repo, number: pr.number, head: pr.headSha,
                    vault: vaultFolder, fallbackFolder: ExplainPR.defaultFolder()))
            explainRecords[pr.id] = ExplainPR.Record(head: out.head, note: out.note, at: Date())
            actionStatus[item.id] = nil
            _ = await Notifier.send(title: "Explained \(pr.ref)", body: "\(pr.repo.fullName): \(pr.title)")
            openNote(for: item)
        } catch {
            actionStatus[item.id] = "Couldn't explain \(pr.ref): \(error.localizedDescription)"
            _ = await Notifier.send(
                title: "Couldn't explain \(pr.ref)", body: error.localizedDescription)
        }
    }

    /// Opens the item's note in Obsidian, or reveals it in Finder when no vault is set (or Obsidian can't).
    func openNote(for item: AttentionItem) {
        guard let record = explainRecords[item.pr.id] else { return }
        if MockMode.isActive {
            actionStatus[item.id] = "Mock mode: this would open \((record.note as NSString).lastPathComponent)."
            return
        }
        guard FileManager.default.fileExists(atPath: record.note) else {
            actionStatus[item.id] = "The note is gone (\((record.note as NSString).abbreviatingWithTildeInPath))."
            return
        }
        let url = URL(fileURLWithPath: record.note)
        let link = ExplainPR.obsidianURL(vault: vaultFolder, note: record.note)
        let obsidianInstalled = link.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        if let link, obsidianInstalled {
            NSWorkspace.shared.open(link)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
