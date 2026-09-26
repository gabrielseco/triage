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
    var digestBaseline: Set<String>? { didSet { save(digestBaseline, "digestBaseline") } }
    /// Item ids the last digest reported as new — what a notification click shows.
    var lastDigestItemIDs: Set<String> { didSet { save(lastDigestItemIDs, "lastDigestItemIDs") } }
    var lastDigestAt: Date? { didSet { save(lastDigestAt, "lastDigestAt") } }
    var openMainWindow: (() -> Void)?

    // Fix in iTerm: repo full name → local clone, and the harness command template.
    var checkoutPaths: [String: String] { didSet { save(checkoutPaths, "checkoutPaths") } }
    var harnessCommand: String { didSet { defaults.set(harnessCommand, forKey: "harnessCommand") } }
    /// Per item: what the last Fix in / Copy did, shown under the buttons.
    var actionStatus: [String: String] = [:]
    /// PRs closed from Triage, hidden until a refresh confirms they're gone from GitHub's open list.
    var closedPRIDs: Set<String> = []
    private var autoRefreshStarted = false
    private var refreshAgain = false
    /// Key read from the key source, held in memory only so it's fetched once per app session.
    var cachedOnePasswordKey: String?

    var prs: [PullRequest] = []
    var items: [AttentionItem] = []
    var stats: [String: PRStats] = [:]
    var viewer: String?
    var isRefreshing = false
    var lastRefresh: Date?
    var errors: [String] = []
    /// Data the last refresh had to leave out (query caps, low rate limit). Unlike errors, doesn't block digests.
    var warnings: [String] = []
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
            .filter { !closedPRIDs.contains($0.pr.id) }
            .filter { !onlyMine || viewer == nil || $0.pr.author == viewer }
            .sorted { ($0.severity, $0.pr.updatedAt) > ($1.severity, $1.pr.updatedAt) }
    }

    /// What Everything and the badges show: active items minus passive ones (waiting on review or CI).
    var inboxItems: [AttentionItem] { activeItems.filter { !$0.kind.isPassive } }

    var visibleItems: [AttentionItem] {
        switch filter {
        case .all: inboxItems
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
        return order.compactMap { id in groups[id].map { ($0[0].pr, $0) } }
    }

    var needsYouCount: Int { activeItems.filter { $0.severity >= .medium }.count }

    var summaryLine: String {
        let needs = needsYouCount
        let waiting = stats.values.filter { $0.pendingChecks > 0 }.count
        let noise = stats.values.reduce(0) { $0 + $1.noiseComments }
        return "\(needs) need you · \(waiting) PRs waiting on CI · \(noise) bot comments muted"
    }

    func count(_ k: AttentionKind) -> Int { activeItems.filter { $0.kind == k }.count }
    func count(repo: String) -> Int { inboxItems.filter { $0.pr.repo.fullName == repo }.count }

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

    func advanceSelection(from item: AttentionItem) {
        let list = visibleItems
        selection = list.first { $0.id != item.id && $0.pr.id == item.pr.id }?.id ?? list.first?.id
    }

    /// Refreshes, or if one is already running, makes it go round once more when done so a repo added
    /// mid-fetch doesn't wait for the next tick.
    func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
    }

    private func refreshOnce() async {
        guard let token = await GitHubAuth.resolveToken() else {
            errors = [GitHubError.noToken.localizedDescription]
            return
        }
        let gh = GitHubClient(token: token)
        if viewer == nil { viewer = try? await gh.viewerLogin() }

        let (merged, errs) = await fetchAll(repos, gh: gh)
        // A repo removed while fetching must not have its PRs brought back.
        let watched = Set(repos)
        let fetched = merged.pullRequests.filter { watched.contains($0.repo) }

        var newItems: [AttentionItem] = []
        var newStats: [String: PRStats] = [:]
        for pr in fetched {
            let (i, s) = Classifier.classify(pr, viewer: viewer)
            newItems += i
            newStats[pr.id] = s
        }
        prs = fetched
        items = newItems
        stats = newStats
        errors = errs
        warnings = merged.allWarnings
        lastRefresh = Date()
        // Forget dismissals/snoozes for items that no longer exist (new push = new ids).
        let live = Set(newItems.map(\.id))
        dismissed = dismissed.intersection(live)
        closedPRIDs.formIntersection(fetched.map(\.id))
        snoozed = snoozed.filter { live.contains($0.key) && $0.value > Date() }
        if !live.contains(selection ?? "") { selection = visibleItems.first?.id }
    }

    /// All repos in parallel. One repo failing doesn't lose the others.
    private func fetchAll(_ repos: [RepoRef], gh: GitHubClient) async -> (RepoSnapshot, errors: [String]) {
        var snapshots: [RepoSnapshot] = []
        var errs: [String] = []
        await withTaskGroup(of: Result<RepoSnapshot, Error>.self) { group in
            for repo in repos {
                group.addTask {
                    do { return .success(try await gh.openPullRequests(repo)) } catch {
                        return .failure(RepoError(repo: repo.fullName, underlying: error))
                    }
                }
            }
            for await r in group {
                switch r {
                case .success(let snap): snapshots.append(snap)
                case .failure(let e): errs.append(e.localizedDescription)
                }
            }
        }
        return (RepoSnapshot.merging(snapshots), errs)
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

    // MARK: - Persistence

    func save<T: Encodable>(_ value: T, _ key: String) {
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
