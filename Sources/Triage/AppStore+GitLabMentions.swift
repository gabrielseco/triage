import Foundation
import TriageCore

/// GitLab @mentions: a banner for each new one, polled every 30 s like Linear pings.
extension AppStore {
    /// Waits one interval first, so the first PR refresh reads the GitLab token (and asks for Touch ID) alone.
    func startGitLabMentions() {
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
        // Without my username a mention of myself would read as someone else's.
        guard !host.isEmpty, let me = gitlabViewer,
            let forge = try? await forgeClient(.gitlab(host: host)) as? GitLabForge,
            let mentions = try? await forge.mentions(),
            host == gitlabHost
        else { return }
        let (alerts, state) = MentionAlerts.plan(mentions, viewer: me, state: mentionAlerts)
        // Saved before sending, so a slow send can't make the next poll notify the same mention again.
        if state != mentionAlerts { mentionAlerts = state }
        guard notifyGitLabMentions else { return }
        for alert in alerts { _ = await Notifier.send(alert) }
    }
}
