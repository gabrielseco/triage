// Prints "<window id> <x> <y> <width> <height>" for Triage's main window (global points), or exits 1.
// CoreGraphics only needs Screen Recording, unlike System Events, which needs Accessibility. Used by scripts/snap.sh.
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
// Optional argument: a PID. Then only that process's windows count and the owner name is ignored, so another running
// Triage (the installed app) is never picked. Used by scripts/verify-app.sh.
let pid = CommandLine.arguments.dropFirst().first.flatMap { Int($0) }
let info = (windows as? [[String: Any]] ?? []).first { window in
    let owned: Bool
    if let pid {
        owned = window[kCGWindowOwnerPID as String] as? Int == pid
    } else {
        owned = window[kCGWindowOwnerName as String] as? String == "Triage"
    }
    return owned && window[kCGWindowLayer as String] as? Int == 0
}
guard let info, let id = info[kCGWindowNumber as String] as? Int,
    let bounds = info[kCGWindowBounds as String] as? [String: Double]
else { exit(1) }
let rect = ["X", "Y", "Width", "Height"].map { String(Int(bounds[$0] ?? 0)) }
print(([String(id)] + rect).joined(separator: " "))
