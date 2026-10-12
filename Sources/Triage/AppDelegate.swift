import AppKit
import ServiceManagement
import TriageCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Owned here rather than by a view so refresh + digests keep running with the window closed.
    let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Notifier.isAvailable {
            UNUserNotificationCenter.current().delegate = self
            Task { await Notifier.requestAuthorization() }
        }
        store.startAutoRefresh()
    }

    /// Show banners even when Triage is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Read here, off the main actor, so only Sendable strings cross into the Task.
        let info = response.notification.request.content.userInfo
        // Only web links: the URL comes from Linear's or GitLab's API, and any other scheme could launch another app.
        let link = (info[Notifier.linearURLKey] as? String) ?? (info[Notifier.mentionURLKey] as? String)
        let pingURL = link.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        let pingKind = (info[Notifier.linearKindKey] as? String).flatMap(LinearPing.Kind.init(rawValue:))
        let reviewRequest = info[Notifier.reviewRequestKey] as? Bool ?? false
        let itemID = info[Notifier.itemIDKey] as? String
        Task { @MainActor in
            if reviewRequest {
                store.filter = .kind(.reviewRequested)
                store.selection = store.visibleItems.first { $0.id == itemID }?.id ?? store.visibleItems.first?.id
                store.showMainWindow()
            } else if let pingURL {
                // A ping is answered in Linear, so the click goes straight to the comment.
                NSWorkspace.shared.open(pingURL)
            } else if let pingKind {
                store.filter = .linear(pingKind)
                store.selectFirstVisible()
                store.showMainWindow()
            } else {
                store.filter = .lastDigest
                store.selection = store.visibleItems.first?.id
                store.showMainWindow()
            }
        }
        completionHandler()
    }
}

enum Notifier {
    /// UNUserNotificationCenter crashes without a bundle id, i.e. when run as a bare `swift run` binary.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func send(title: String, body: String) async -> Bool {
        guard isAvailable else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "digest-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(req); return true } catch { return false }
    }

    /// Where a click on a Linear notification goes: the comment for one ping, the Linear list for a summary.
    static let linearURLKey = "linearURL"
    static let linearKindKey = "linearKind"

    /// Which item a click on a review-request notification selects; a summary has none and shows them all.
    static let itemIDKey = "itemID"
    static let reviewRequestKey = "reviewRequest"

    static func send(_ alert: ReviewRequestAlert) async -> Bool {
        guard isAvailable else { return false }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = "review-requests"
        content.userInfo = [reviewRequestKey: true, itemIDKey: alert.item?.id ?? ""]
        let req = UNNotificationRequest(identifier: "review-\(UUID().uuidString)", content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(req); return true } catch { return false }
    }

    /// Where a click on a GitLab mention goes: the comment.
    static let mentionURLKey = "mentionURL"

    static func send(_ alert: MentionAlert) async -> Bool {
        guard isAvailable else { return false }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = "gitlab-mentions"
        content.userInfo = [mentionURLKey: alert.url.absoluteString]
        let req = UNNotificationRequest(identifier: "mention-\(UUID().uuidString)", content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(req); return true } catch { return false }
    }

    static func send(_ alert: PingAlert) async -> Bool {
        guard isAvailable else { return false }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.threadIdentifier
        if let ping = alert.ping {
            content.userInfo = [linearURLKey: ping.url.absoluteString]
        } else if case .summary(_, let newest) = alert {
            content.userInfo = [linearKindKey: newest.kind.rawValue]
        }
        let req = UNNotificationRequest(identifier: "linear-\(UUID().uuidString)", content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(req); return true } catch { return false }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

enum ITerm {
    struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Opens a new iTerm window running `path`. First use shows macOS's "Triage wants to control iTerm" prompt.
    /// Runs through `osascript` rather than NSAppleScript, which is main-thread only and would freeze the UI
    /// while iTerm launches or the permission prompt is up. Triage stays the responsible process for the prompt.
    static func open(runningScript path: String) async throws {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "iTerm"
              activate
              create window with default profile command "\(escaped)"
            end tell
            """
        let out = try await Subprocess.run("/usr/bin/osascript", ["-e", source])
        guard out.status == 0 else {
            let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScriptError(
                message: "\(msg.isEmpty ? "AppleScript error" : msg) — allow Triage under System Settings → "
                    + "Privacy & Security → Automation → iTerm.")
        }
    }
}
