import AppKit
import Foundation
import Observation
import TriageCore

enum ExplainState: Equatable {
    case loading
    case done(String)
    case failed(String)
}

enum SidebarFilter: Hashable {
    case all
    case kind(AttentionKind)
    case repo(String)
    case lastDigest
}

@MainActor @Observable
final class AppStore {
    private let defaults = UserDefaults.standard

    var repos: [RepoRef] { didSet { save(repos, "repos") } }
    var dismissed: Set<String> { didSet { save(dismissed, "dismissed") } }
    var snoozed: [String: Date] { didSet { save(snoozed, "snoozed") } }
    var onlyMine: Bool { didSet { defaults.set(onlyMine, forKey: "onlyMine") } }
    var model: String { didSet { defaults.set(model, forKey: "model") } }
    /// e.g. op://Employee/Anthropic API/credential. Only the reference is stored, never the key.
    var onePasswordRef: String {
        didSet {
            defaults.set(onePasswordRef, forKey: "onePasswordRef")
            cachedOnePasswordKey = nil
        }
    }

    // Digest: at each scheduled hour, notify what's new since the previous digest.
    var digestHours: [Int] { didSet { save(digestHours, "digestHours") } }
    var digestWeekdaysOnly: Bool { didSet { defaults.set(digestWeekdaysOnly, forKey: "digestWeekdaysOnly") } }
    /// Item ids open at the last digest — the baseline "new" is measured against.
    private(set) var digestBaseline: Set<String>? { didSet { save(digestBaseline, "digestBaseline") } }
    /// Item ids the last digest reported as new — what a notification click shows.
    private(set) var lastDigestItemIDs: Set<String> { didSet { save(lastDigestItemIDs, "lastDigestItemIDs") } }
    private(set) var lastDigestAt: Date? { didSet { save(lastDigestAt, "lastDigestAt") } }
    var openMainWindow: (() -> Void)?

    // Fix in iTerm: repo full name → local clone, and the harness command template.
    var checkoutPaths: [String: String] { didSet { save(checkoutPaths, "checkoutPaths") } }
    var harnessCommand: String { didSet { defaults.set(harnessCommand, forKey: "harnessCommand") } }
    /// Per item: what the last Fix in / Copy did, shown under the buttons.
    var actionStatus: [String: String] = [:]
    private var autoRefreshStarted = false

    var prs: [PullRequest] = []
    var items: [AttentionItem] = []
    var stats: [String: PRStats] = [:]
    var viewer: String?
    var isRefreshing = false
    var lastRefresh: Date?
    var errors: [String] = []
    var explanations: [String: ExplainState] = [:]
    var filter: SidebarFilter = .all
    var selection: String?

    init() {
        repos = Self.load("repos") ?? []
        dismissed = Self.load("dismissed") ?? []
        snoozed = Self.load("snoozed") ?? [:]
        onlyMine = UserDefaults.standard.bool(forKey: "onlyMine")
        model = UserDefaults.standard.string(forKey: "model") ?? AnthropicClient.defaultModel
        onePasswordRef = UserDefaults.standard.string(forKey: "onePasswordRef") ?? ""
        checkoutPaths = Self.load("checkoutPaths") ?? [:]
        harnessCommand = UserDefaults.standard.string(forKey: "harnessCommand") ?? Handoff.defaultHarnessCommand
        digestHours = Self.load("digestHours") ?? [12, 18]
        digestWeekdaysOnly = UserDefaults.standard.object(forKey: "digestWeekdaysOnly") as? Bool ?? true
        digestBaseline = Self.load("digestBaseline")
        lastDigestItemIDs = Self.load("lastDigestItemIDs") ?? []
        lastDigestAt = Self.load("lastDigestAt")
    }

    // MARK: - Derived

    /// Everything that currently needs a look, most severe first.
    var activeItems: [AttentionItem] {
        let now = Date()
        return
            items
            .filter { !dismissed.contains($0.id) && (snoozed[$0.id] ?? .distantPast) < now }
            .filter { !onlyMine || viewer == nil || $0.pr.author == viewer }
            .sorted { ($0.severity, $0.pr.updatedAt) > ($1.severity, $1.pr.updatedAt) }
    }

    var visibleItems: [AttentionItem] {
        switch filter {
        case .all: activeItems
        case .kind(let k): activeItems.filter { $0.kind == k }
        case .repo(let r): activeItems.filter { $0.pr.repo.fullName == r }
        case .lastDigest: activeItems.filter { lastDigestItemIDs.contains($0.id) }
        }
    }

    /// Items grouped by PR, groups ordered by their worst item.
    var groupedVisible: [(pr: PullRequest, items: [AttentionItem])] {
        var order: [String] = []
        var groups: [String: [AttentionItem]] = [:]
        for item in visibleItems {
            if groups[item.pr.id] == nil { order.append(item.pr.id) }
            groups[item.pr.id, default: []].append(item)
        }
        return order.map { (groups[$0]![0].pr, groups[$0]!) }
    }

    var needsYouCount: Int { activeItems.filter { $0.severity >= .medium }.count }

    var summaryLine: String {
        let needs = needsYouCount
        let waiting = stats.values.filter { $0.pendingChecks > 0 }.count
        let noise = stats.values.reduce(0) { $0 + $1.noiseComments }
        return "\(needs) need you · \(waiting) PRs waiting on CI · \(noise) bot comments muted"
    }

    func count(_ k: AttentionKind) -> Int { activeItems.filter { $0.kind == k }.count }
    func count(repo: String) -> Int { activeItems.filter { $0.pr.repo.fullName == repo }.count }

    var selectedItem: AttentionItem? { items.first { $0.id == selection } }

    // MARK: - Actions

    func addRepo(_ text: String) -> Bool {
        guard let r = RepoRef(string: text), !repos.contains(r) else { return false }
        repos.append(r)
        Task { await refresh() }
        return true
    }

    func removeRepo(_ r: RepoRef) {
        repos.removeAll { $0 == r }
        items.removeAll { $0.pr.repo == r }
        prs.removeAll { $0.repo == r }
    }

    func dismiss(_ item: AttentionItem) {
        dismissed.insert(item.id)
        advanceSelection(from: item)
    }

    func snooze(_ item: AttentionItem, for interval: TimeInterval) {
        snoozed[item.id] = Date().addingTimeInterval(interval)
        advanceSelection(from: item)
    }

    func restoreHidden() {
        dismissed = []
        snoozed = [:]
    }

    private func advanceSelection(from item: AttentionItem) {
        let list = visibleItems
        selection = list.first { $0.id != item.id && $0.pr.id == item.pr.id }?.id ?? list.first?.id
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let token = GitHubAuth.resolveToken() else {
            errors = [GitHubError.noToken.localizedDescription]
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let gh = GitHubClient(token: token)
        if viewer == nil { viewer = try? await gh.viewerLogin() }

        var fetched: [PullRequest] = []
        var errs: [String] = []
        await withTaskGroup(of: Result<[PullRequest], Error>.self) { group in
            for repo in repos {
                group.addTask {
                    do { return .success(try await gh.openPullRequests(repo)) } catch {
                        return .failure(RepoError(repo: repo.fullName, underlying: error))
                    }
                }
            }
            for await r in group {
                switch r {
                case .success(let p): fetched += p
                case .failure(let e): errs.append(e.localizedDescription)
                }
            }
        }

        var newItems: [AttentionItem] = []
        var newStats: [String: PRStats] = [:]
        for pr in fetched {
            let (i, s) = Classifier.classify(pr)
            newItems += i
            newStats[pr.id] = s
        }
        prs = fetched
        items = newItems
        stats = newStats
        errors = errs
        lastRefresh = Date()
        // Forget dismissals/snoozes for items that no longer exist (new push = new ids).
        let live = Set(newItems.map(\.id))
        dismissed = dismissed.intersection(live)
        snoozed = snoozed.filter { live.contains($0.key) && $0.value > Date() }
        if selection == nil || !live.contains(selection!) { selection = visibleItems.first?.id }
    }

    func startAutoRefresh() {
        guard !autoRefreshStarted else { return }
        autoRefreshStarted = true
        Task {
            while true {
                await refresh()
                await sendDigestIfDue()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func showMainWindow() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Digest

    /// Called after every refresh. Sends at most one digest per scheduled slot; if the Mac was asleep
    /// or the app closed at 12:00, the 12:00 digest goes out on the next refresh after that.
    func sendDigestIfDue(now: Date = Date()) async {
        guard lastRefresh != nil, errors.count < max(repos.count, 1) else { return }  // don't digest stale data
        guard digestBaseline != nil else {
            // First run: everything open now is the baseline, so the first digest isn't "13 new".
            digestBaseline = Set(activeItems.map(\.id))
            lastDigestAt = now
            return
        }
        guard
            let slot = DigestBuilder.latestSlot(atOrBefore: now, hours: digestHours, weekdaysOnly: digestWeekdaysOnly),
            (lastDigestAt ?? .distantPast) < slot
        else { return }
        await sendDigest(force: false, now: now)
    }

    func sendDigest(force: Bool, now: Date = Date()) async {
        if force { await refresh() }
        let current = activeItems
        let digest = DigestBuilder.build(current: current, previousIDs: digestBaseline ?? [], since: lastDigestAt)
        guard await Notifier.send(title: digest.title, body: digest.body) || force else { return }
        lastDigestItemIDs = Set(digest.newItems.map(\.id))
        digestBaseline = Set(current.map(\.id))
        lastDigestAt = now
    }

    // MARK: - AI

    func buildPrompt(for item: AttentionItem, mode: PromptMode) async -> String {
        var ctx = PromptContext()
        if let token = GitHubAuth.resolveToken() {
            let gh = GitHubClient(token: token)
            let repo = item.pr.repo
            if item.kind == .ciFailure {
                for e in item.evidence.prefix(3) {
                    guard let id = e.checkRunID else { continue }
                    if let log = await gh.jobLog(repo, jobID: id) {
                        ctx.checkOutputs.append((e.title, log))
                    } else if let out = await gh.checkRunOutput(repo, id: id) {
                        ctx.checkOutputs.append((e.title, out))
                    }
                }
            }
            ctx.diff = await gh.diff(repo, number: item.pr.number)
        }
        return PromptBuilder.prompt(for: item, context: ctx, mode: mode)
    }

    func copyPrompt(for item: AttentionItem, mode: PromptMode) async {
        actionStatus[item.id] = "Fetching logs and diff…"
        let text = await buildPrompt(for: item, mode: mode)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actionStatus[item.id] = "Copied prompt (\(text.count / 1000) KB) to the clipboard"
    }

    // MARK: - Fix in iTerm

    static let checkoutRoots = ["~/remote", "~/rogal", "~/code", "~/src", "~/dev", "~/projects", "~/Developer", "~"]
        .map { ($0 as NSString).expandingTildeInPath }

    /// Remembered path, else auto-detected (`<root>/<repo name>` whose origin is this repo) and remembered.
    func checkoutPath(for repo: RepoRef) -> String? {
        if let p = checkoutPaths[repo.fullName], FileManager.default.fileExists(atPath: p) { return p }
        guard let found = Handoff.findCheckout(repo, roots: Self.checkoutRoots) else { return nil }
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
        guard let checkout = checkoutPath(for: repo) ?? chooseCheckout(for: repo) else {
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
            try ITerm.open(runningScript: scriptURL.path)
            actionStatus[item.id] = "Opened iTerm in \((plan.worktree as NSString).abbreviatingWithTildeInPath)"
        } catch {
            actionStatus[item.id] = "Couldn't hand off: \(error.localizedDescription)"
        }
    }

    enum KeySource: String {
        case onePassword = "1Password / key helper", environment = "ANTHROPIC_API_KEY", keychain = "Keychain", none =
            "not set"
    }

    /// Which key Explain will use. A configured 1Password reference wins: it's the explicit choice made in
    /// this app (e.g. the work key), whereas the environment may hold an unrelated personal key.
    var keySource: KeySource {
        if !onePasswordRef.isEmpty { return .onePassword }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return .environment }
        if Keychain.get("anthropic") != nil { return .keychain }
        return .none
    }

    /// Key read from 1Password, held in memory only so Touch ID is asked once per app session.
    private var cachedOnePasswordKey: String?

    func resolveAPIKey() async throws -> String {
        switch keySource {
        case .onePassword:
            if let k = cachedOnePasswordKey { return k }
            let k = try await KeyReference.read(onePasswordRef)
            cachedOnePasswordKey = k
            return k
        case .environment: return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!
        case .keychain: return Keychain.get("anthropic")!
        case .none: throw AnthropicError.noKey
        }
    }

    func explain(_ item: AttentionItem) async {
        explanations[item.id] = .loading
        do {
            let key = try await resolveAPIKey()
            let prompt = await buildPrompt(for: item, mode: .explain)
            let text = try await AnthropicClient(apiKey: key, model: model)
                .complete(system: PromptBuilder.systemPrompt, prompt: prompt)
            explanations[item.id] = .done(text)
        } catch {
            // A rotated key in 1Password: forget the cached one so the next try re-reads it.
            if case AnthropicError.http(401, _) = error { cachedOnePasswordKey = nil }
            explanations[item.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Persistence

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

struct RepoError: LocalizedError {
    let repo: String
    let underlying: Error
    var errorDescription: String? { "\(repo): \(underlying.localizedDescription)" }
}
