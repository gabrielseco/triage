import AppKit
import Foundation
import TriageCore

/// Scheduled digests: what's new since the previous one, as a macOS notification.
extension AppStore {
    // MARK: - Digest

    /// Called after every refresh. Sends at most one digest per scheduled slot; if the Mac was asleep
    /// or the app closed at 12:00, the 12:00 digest goes out on the next refresh after that.
    func sendDigestIfDue(now: Date = Date()) async {
        guard lastRefresh != nil, errors.count < max(repos.count, 1) else { return }  // don't digest stale data
        guard digestBaseline != nil else {
            // First run: everything open now is the baseline, so the first digest isn't "13 new".
            digestBaseline = Set(DigestBuilder.tracked(activeItems).map(\.id))
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
        let digest = DigestBuilder.build(current: activeItems, previousIDs: digestBaseline ?? [], since: lastDigestAt)
        guard await Notifier.send(title: digest.title, body: digest.body) || force else { return }
        lastDigestItemIDs = Set(digest.newItems.map(\.id))
        digestBaseline = digest.trackedIDs
        lastDigestAt = now
    }
}
