import Foundation
import TriageCore

/// The last mentions poll. Kept apart from `errors`, which each PR refresh replaces.
struct GitLabMentionsState {
    /// Waiting on me, newest first, before dismissals and snoozes.
    var waiting: [GitLabMention] = []
    /// Nil until the first poll succeeds, so the list shows progress instead of "Inbox zero".
    var lastRefresh: Date?
    var loopStarted = false
}

/// GitLab @mentions waiting on my reply: the sidebar's GitLab › Mentioned, and a banner for each new one,
/// polled every 30 s like Linear pings.
extension AppStore {
    /// Linear pings and GitLab mentions prune their own dismissals and snoozes; a PR refresh leaves them alone.
    static func isPingOrMentionID(_ id: String) -> Bool { LinearPing.isPingID(id) || GitLabMention.isMentionID(id) }

    /// Waiting mentions minus the ones dismissed or snoozed in Triage.
    var activeMentions: [GitLabMention] {
        let now = Date()
        return gitlabMentions.waiting.filter { !dismissed.contains($0.id) && (snoozed[$0.id] ?? .distantPast) < now }
    }

    var visibleMentions: [GitLabMention] { filter == .gitlabMentions ? activeMentions : [] }

    /// Only a mention the list is showing, like `selectedItem`.
    var selectedMention: GitLabMention? { visibleMentions.first { $0.id == selection } }

    /// Every 30 s, starting 30 s in, so the first PR refresh reads the GitLab token (and asks for Touch ID) alone.
    func startGitLabMentions() {
        guard !gitlabMentions.loopStarted else { return }
        gitlabMentions.loopStarted = true
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                await pollGitLabMentions()
            }
        }
    }

    /// Failures are quiet: the PR refresh already reports a bad token or an unreachable GitLab.
    func pollGitLabMentions() async {
        let host = gitlabHost
        // Without my username a reply from me couldn't be recognized, nor a mention of myself.
        guard !host.isEmpty, let me = gitlabViewer,
            let forge = try? await forgeClient(.gitlab(host: host)) as? GitLabForge,
            let mentions = try? await forge.mentions(),
            host == gitlabHost
        else { return }
        let now = Date()
        let waiting = GitLabMentions.waiting(mentions, viewer: me, now: now)
        gitlabMentions.waiting = waiting
        gitlabMentions.lastRefresh = now
        // Replied to, merged or aged out: its dismissal or snooze goes too.
        let live = Set(waiting.map(\.id))
        dismissed = dismissed.filter { !GitLabMention.isMentionID($0) || live.contains($0) }
        snoozed = snoozed.filter { !GitLabMention.isMentionID($0.key) || (live.contains($0.key) && $0.value > now) }
        if filter == .gitlabMentions, selectedMention == nil { selectFirstVisible() }

        let active = Set(activeMentions.map(\.id))
        let (alerts, state) = MentionAlerts.plan(
            waiting.filter { active.contains($0.id) }, viewer: me, state: mentionAlerts)
        // Saved before sending, so a slow send can't make the next poll notify the same mention again.
        if state != mentionAlerts { mentionAlerts = state }
        guard notifyGitLabMentions else { return }
        for alert in alerts { _ = await Notifier.send(alert) }
    }

    /// GitLab turned off or pointed elsewhere: its mentions go; dismissals stay for when it's back.
    func clearGitLabMentions() {
        gitlabMentions.waiting = []
        gitlabMentions.lastRefresh = nil
        if filter == .gitlabMentions { filter = .all }
    }
}
