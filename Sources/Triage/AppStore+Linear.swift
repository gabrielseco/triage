import Foundation
import TriageCore

/// Linear's side of the store. Kept apart from `errors` and `warnings`, which each PR refresh replaces and which
/// gate digests.
struct LinearState {
    /// Open pings from the last fetch, newest first, before dismissals and snoozes.
    var pings: [LinearPing] = []
    var errors: [String] = []
    var warnings: [String] = []
    /// Read from the Keychain once per session.
    var cachedKey: String?
    var isRefreshing = false
    var loopStarted = false
    /// Nil until the first fetch succeeds, so the list shows progress instead of "Inbox zero".
    var lastRefresh: Date?
}

/// Linear pings: mentions and replies in my threads that I haven't answered (docs/plans/LINEAR.md).
extension AppStore {
    /// The first row of whatever list is showing, PR items or Linear pings.
    func selectFirstVisible() {
        selection = visibleItems.first?.id ?? visiblePings.first?.id
    }

    /// Open pings minus the ones dismissed or snoozed in Triage, newest first.
    var activePings: [LinearPing] {
        let now = Date()
        return linear.pings.filter { !dismissed.contains($0.id) && (snoozed[$0.id] ?? .distantPast) < now }
    }

    var visiblePings: [LinearPing] {
        guard case .linear(let kind) = filter else { return [] }
        return activePings.filter { $0.kind == kind }
    }

    /// Only a ping the list is showing, like `selectedItem`.
    var selectedPing: LinearPing? { visiblePings.first { $0.id == selection } }

    func count(_ kind: LinearPing.Kind) -> Int { activePings.filter { $0.kind == kind }.count }

    func dismiss(_ ping: LinearPing) {
        dismissed.insert(ping.id)
        advanceSelection(from: ping)
    }

    func snooze(_ ping: LinearPing, for interval: TimeInterval) {
        snoozed[ping.id] = Date().addingTimeInterval(interval)
        advanceSelection(from: ping)
    }

    private func advanceSelection(from ping: LinearPing) {
        selection = visiblePings.first { $0.id != ping.id }?.id
    }

    /// Saves a pasted key, or removes it when empty, and fetches with it.
    func saveLinearKey(_ key: String) throws {
        try Keychain.set(key, for: LinearAuth.keychainAccount, service: LinearAuth.keychainService)
        linear.cachedKey = nil
        Task { await refreshLinear() }
    }

    func linearClient() throws -> LinearClient {
        guard let key = linear.cachedKey ?? LinearAuth.key() else { throw LinearError.noKey }
        linear.cachedKey = key
        return LinearClient(key: key)
    }

    /// Every 30 s rather than with the 2-minute PR refresh, so a ping shows up soon after it's sent.
    func startLinearRefresh() {
        guard !linear.loopStarted else { return }
        linear.loopStarted = true
        Task {
            while true {
                await refreshLinear()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refreshLinear() async {
        guard linearEnabled, !linear.isRefreshing else { return }
        linear.isRefreshing = true
        defer { linear.isRefreshing = false }
        do {
            let (notifications, warnings) = try await linearClient().notifications()
            // Turned off while fetching: don't bring the pings back.
            guard linearEnabled else { return }
            let pings = LinearPings.classify(notifications, now: Date())
            let live = Set(pings.map(\.id))
            linear.pings = pings
            linear.errors = []
            linear.warnings = warnings
            linear.lastRefresh = Date()
            dismissed = LinearPings.pruneHidden(dismissed, live: live)
            let now = Date()
            snoozed = snoozed.filter { !LinearPing.isPingID($0.key) || (live.contains($0.key) && $0.value > now) }
            if case .linear = filter, selectedPing == nil { selectFirstVisible() }
        } catch {
            guard linearEnabled else { return }
            // Keep the last pings on screen; a failed poll every 30 s shouldn't empty the list.
            linear.errors = ["Linear: \(error.localizedDescription)"]
        }
    }

    /// Linear turned off: its pings, errors and cached key go; dismissals stay for when it's back on.
    func clearLinear() {
        linear.pings = []
        linear.errors = []
        linear.warnings = []
        linear.cachedKey = nil
        linear.lastRefresh = nil
        if case .linear = filter { filter = .all }
    }
}
