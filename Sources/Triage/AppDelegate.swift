import AppKit
import ServiceManagement
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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            store.filter = .lastDigest
            store.selection = store.visibleItems.first?.id
            store.showMainWindow()
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
        let req = UNNotificationRequest(identifier: "digest-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
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
    static func open(runningScript path: String) throws {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm"
          activate
          create window with default profile command "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            throw ScriptError(message: "\(msg) — allow Triage under System Settings → Privacy & Security → Automation → iTerm.")
        }
    }
}
