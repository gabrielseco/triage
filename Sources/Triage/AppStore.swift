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
    case linear(LinearPing.Kind)
}

@MainActor @Observable
final class AppStore {
    private let defaults = UserDefaults.standard

    var repos: [RepoRef] { didSet { save(repos, "repos") } }
    var dismissed: Set<String> { didSet { save(dismissed, "dismissed") } }
    var snoozed: [String: Date] { didSet { save(snoozed, "snoozed") } }
    /// When each repo started being watched and which new PRs were dismissed: the rest show a New PR item.
    var seenPRs: SeenPRs { didSet { save(seenPRs, "seenPRs") } }
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
    /// A banner as soon as someone asks for my review, instead of waiting for the digest. On by default.
    var notifyReviewRequests: Bool { didSet { defaults.set(notifyReviewRequests, forKey: "notifyReviewRequests") } }
    /// Which review requests were notified, so each notifies once, even across restarts.
    var reviewRequestAlerts: ReviewRequestAlertState { didSet { save(reviewRequestAlerts, "reviewRequestAlerts") } }
    var openMainWindow: (() -> Void)?

    // Fix in iTerm: repo full name → local clone, and the harness command template.
    var checkoutPaths: [String: String] { didSet { save(checkoutPaths, "checkoutPaths") } }
    var harnessCommand: String { didSet { defaults.set(harnessCommand, forKey: "harnessCommand") } }
    /// The GitLab instance whose merge requests (assigned to you or waiting on your review) are shown, e.g.
    /// gitlab.com. Empty means GitLab is off. The token lives in the Keychain, never here.
    var gitlabHost: String {
        didSet {
            defaults.set(gitlabHost, forKey: "gitlabHost")
            gitlabViewer = nil
            cachedGitLabToken = nil
        }
    }
    /// Linear pings (mentions and replies in my threads) on their own 30 s loop. The key lives in the Keychain.
    var linearEnabled: Bool {
        didSet {
            defaults.set(linearEnabled, forKey: "linearEnabled")
            if !linearEnabled { clearLinear() }
        }
    }
    /// A banner per new ping, then reminders until it's answered. On by default.
    var notifyPings: Bool { didSet { defaults.set(notifyPings, forKey: "notifyPings") } }
    /// Which pings were notified and when, so each notifies once, even across restarts.
    var pingAlerts: PingAlertState { didSet { save(pingAlerts, "pingAlerts") } }
    /// Per item: what the last Fix in / Copy did, shown under the buttons.
    var actionStatus: [String: String] = [:]
    /// PRs closed or merged from Triage, hidden until a refresh confirms they're gone from GitHub's open list.
    var closedPRIDs: Set<String> = []
    /// `repo#number@headSha` approved from Triage, so Approve hides before a refresh reports the review.
    var approvedHeads: Set<String> = []
    /// The merge or close waiting for a yes in the item detail.
    var confirming: PRConfirmation?
    private var autoRefreshStarted = false
    private var refreshAgain = false
    /// Key read from the key source, held in memory only so it's fetched once per app session.
    var cachedOnePasswordKey: String?
    /// The GitLab token, read from the Keychain once per session rather than on every refresh.
    var cachedGitLabToken: String?

    var prs: [PullRequest] = []
    var items: [AttentionItem] = []
    var stats: [String: PRStats] = [:]
    /// The GitHub login.
    var viewer: String?
    /// The GitLab username, which is usually different.
    var gitlabViewer: String?
    var isRefreshing = false
    var lastRefresh: Date?
    var errors: [String] = []
    /// Data the last refresh had to leave out (query caps, low rate limit). Unlike errors, doesn't block digests.
    var warnings: [String] = []
    var explanations: [String: ExplainState] = [:]
    var linear = LinearState()
    var filter: SidebarFilter = .all {
        // The selected item may not be in the new list; move to its first item so the detail matches.
        didSet { if selectedItem == nil, selectedPing == nil { selectFirstVisible() } }
    }
    var selection: String? {
        // A merge or close asked for another item isn't answered by this one, nor later by surprise.
        didSet { if confirming?.item.id != selection { confirming = nil } }
    }

    init() {
        repos = Self.load("repos") ?? []
        dismissed = Self.load("dismissed") ?? []
        snoozed = Self.load("snoozed") ?? [:]
        seenPRs = Self.load("seenPRs") ?? SeenPRs()
        onlyMine = UserDefaults.standard.bool(forKey: "onlyMine")
        model = UserDefaults.standard.string(forKey: "model") ?? AnthropicClient.defaultModel
        onePasswordRef = UserDefaults.standard.string(forKey: "onePasswordRef") ?? ""
        checkoutPaths = Self.load("checkoutPaths") ?? [:]
        harnessCommand = UserDefaults.standard.string(forKey: "harnessCommand") ?? Handoff.defaultHarnessCommand
        gitlabHost = UserDefaults.standard.string(forKey: "gitlabHost") ?? ""
        linearEnabled = UserDefaults.standard.bool(forKey: "linearEnabled")
        notifyPings = UserDefaults.standard.object(forKey: "notifyPings") as? Bool ?? true
        pingAlerts = Self.load("pingAlerts") ?? PingAlertState()
        digestHours = Self.load("digestHours") ?? [12, 18]
        digestWeekdaysOnly = UserDefaults.standard.object(forKey: "digestWeekdaysOnly") as? Bool ?? true
        digestBaseline = Self.load("digestBaseline")
        lastDigestItemIDs = Self.load("lastDigestItemIDs") ?? []
        lastDigestAt = Self.load("lastDigestAt")
        notifyReviewRequests = UserDefaults.standard.object(forKey: "notifyReviewRequests") as? Bool ?? true
        reviewRequestAlerts = Self.load("reviewRequestAlerts") ?? ReviewRequestAlertState()
    }

    // MARK: - Derived

    /// Everything that currently needs a look, most severe first.
    var activeItems: [AttentionItem] {
        let now = Date()
        return
            items
            .filter { !dismissed.contains($0.id) && (snoozed[$0.id] ?? .distantPast) < now }
            .filter { !closedPRIDs.contains($0.pr.id) }
            .filter { item in
                // A review asked of me is mine to do, whoever wrote the PR.
                guard onlyMine, item.kind != .reviewRequested, let me = viewer(for: item.pr.repo.forge) else {
                    return true
                }
                return item.pr.author == me
            }
            .sorted { ($0.severity, $0.pr.updatedAt) > ($1.severity, $1.pr.updatedAt) }
    }

    /// What Everything and the badges show: active items minus passive ones (waiting on review or CI).
    var inboxItems: [AttentionItem] { activeItems.filter { !$0.kind.isPassive } }

    var visibleItems: [AttentionItem] {
        switch filter {
        case .all: inboxItems
        case .kind(.awaitingReview): activeItems.filter { $0.kind == .awaitingReview }.sortedByCreation()
        case .kind(let k): activeItems.filter { $0.kind == k }
        case .repo(let r): activeItems.filter { $0.pr.repo.id == r }
        case .lastDigest: activeItems.filter { lastDigestItemIDs.contains($0.id) }
        case .linear: []
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
    func count(repo: String) -> Int { inboxItems.filter { $0.pr.repo.id == repo }.count }

    /// Only an item the list is showing, so the detail never shows one hidden by the filter, a dismissal or
    /// "Only mine".
    var selectedItem: AttentionItem? { visibleItems.first { $0.id == selection } }

    // MARK: - Actions

    func dismiss(_ item: AttentionItem) {
        dismissed.insert(item.id)
        if item.kind == .newPR { seenPRs.dismiss(item.pr) }
        advanceSelection(from: item)
    }

    func snooze(_ item: AttentionItem, for interval: TimeInterval) {
        snoozed[item.id] = Date().addingTimeInterval(interval)
        advanceSelection(from: item)
    }

    func restoreHidden() {
        dismissed = []
        snoozed = [:]
        seenPRs.undismissAll()
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
        // ⌘R refreshes Linear too, instead of waiting up to 30 s.
        async let linear: Void = refreshLinear()
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
        await linear
    }

    private func refreshOnce() async {
        async let github = fetchGitHub()
        async let gitlab = fetchGitLab()
        let (gh, gl) = await (github, gitlab)
        // Checked after the fetch: a repo removed, or GitLab turned off or pointed elsewhere, while fetching
        // must not bring back its PRs, warnings or errors.
        let current = Set(repos)
        let host = gitlabHost
        let results =
            gh.results.filter { current.contains($0.repo) }
            + (host.isEmpty ? [] : gl.results.filter { $0.repo.forge == .gitlab(host: host) })
        let merged = RepoSnapshot.merging(results.compactMap { try? $0.result.get() })
        let errs =
            gh.errors + (host.isEmpty ? [] : gl.errors)
            + results.compactMap { r -> String? in
                guard case .failure(let e) = r.result else { return nil }
                return e.localizedDescription
            }
        let fetched = merged.pullRequests
        var seen = seenPRs
        seen.startWatching(results.filter { (try? $0.result.get()) != nil }.map(\.repo))

        var newItems: [AttentionItem] = []
        var newStats: [String: PRStats] = [:]
        for pr in fetched {
            let (i, s) = Classifier.classify(pr, viewer: viewer(for: pr.repo.forge), isNew: seen.isNew(pr))
            newItems += i
            newStats[pr.id] = s
        }
        prs = fetched
        seenPRs = seen
        items = newItems
        stats = newStats
        errors = errs
        warnings = merged.allWarnings
        lastRefresh = Date()
        // Forget dismissals/snoozes for items that no longer exist (new push = new ids). Linear pings are
        // pruned by their own loop, against their own ids.
        let live = Set(newItems.map(\.id))
        dismissed = dismissed.filter { live.contains($0) || LinearPing.isPingID($0) }
        closedPRIDs.formIntersection(fetched.map(\.id))
        snoozed = snoozed.filter { (live.contains($0.key) || LinearPing.isPingID($0.key)) && $0.value > Date() }
        if !live.contains(selection ?? ""), selectedPing == nil { selectFirstVisible() }
        await notifyReviewRequests(complete: errs.isEmpty)
    }

    private struct Fetched {
        var results: [RepoResult] = []
        var errors: [String] = []
    }

    private func fetchGitHub() async -> Fetched {
        do {
            let client = try await forgeClient(.github, repos: repos)
            if viewer == nil { viewer = try? await client.viewer() }
            return Fetched(results: try await client.fetch())
        } catch {
            return Fetched(errors: [error.localizedDescription])
        }
    }

    private func fetchGitLab() async -> Fetched {
        guard !gitlabHost.isEmpty else { return Fetched() }
        do {
            let client = try await forgeClient(.gitlab(host: gitlabHost))
            if gitlabViewer == nil { gitlabViewer = try? await client.viewer() }
            return Fetched(results: try await client.fetch())
        } catch {
            return Fetched(errors: ["GitLab: \(error.localizedDescription)"])
        }
    }

    func startAutoRefresh() {
        guard !autoRefreshStarted else { return }
        autoRefreshStarted = true
        startLinearRefresh()
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
}

// MARK: - Repos

extension AppStore {
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
        seenPRs.stopWatching(r)
        // Warnings and errors are strings led by the repo ("owner/name: …", "owner/name#7: …").
        let isAbout = { (line: String) in line.hasPrefix("\(r.fullName):") || line.hasPrefix("\(r.fullName)#") }
        warnings.removeAll(where: isAbout)
        errors.removeAll(where: isAbout)
    }
}
