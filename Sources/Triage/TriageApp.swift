import AppKit
import SwiftUI
import TriageCore

@main
struct TriageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Running from `swift run` there's no bundle; make it a normal foreground app with a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        Window("Triage", id: "main") {
            ContentView()
                .environment(delegate.store)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await delegate.store.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandMenu("Pull Request") {
                if let item = delegate.store.selectedItem {
                    PullRequestActions(item: item, inMenuBar: true).environment(delegate.store)
                } else {
                    Text("Select an item to act on its PR")
                }
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }

        Settings {
            SettingsView().environment(delegate.store)
        }
    }
}

/// Always rendered (it's the menu bar icon), so it's where we grab `openWindow` for the store —
/// notification clicks need to reopen the main window even after it was closed.
struct MenuBarLabel: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("\(store.needsYouCount)", systemImage: store.needsYouCount > 0 ? "tray.full.fill" : "tray")
            .onAppear { store.openMainWindow = { openWindow(id: "main") } }
    }
}

struct MenuBarContent: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Text(store.summaryLine)
        if let at = store.lastDigestAt {
            Text("Last digest \(at.formatted(date: .omitted, time: .shortened))")
        }
        Divider()
        ForEach(store.activeItems.filter { $0.severity >= .medium }.prefix(10)) { item in
            Button(String("\(item.pr.repo.name)#\(item.pr.number) · \(item.kind.title): \(item.headline)")) {
                store.filter = .all
                store.selection = item.id
                store.showMainWindow()
            }
        }
        Divider()
        Button("Open Triage") { store.showMainWindow() }
        Button("Send digest now") { Task { await store.sendDigest(force: true) } }
        Button("Refresh") { Task { await store.refresh() } }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
