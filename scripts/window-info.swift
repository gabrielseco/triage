// Prints "<window id> <x> <y> <width> <height>" for Triage's main window (global points), or exits 1.
// CoreGraphics only needs Screen Recording, unlike System Events, which needs Accessibility. Used by scripts/snap.sh.
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
let info = (windows as? [[String: Any]] ?? []).first {
    $0[kCGWindowOwnerName as String] as? String == "Triage" && $0[kCGWindowLayer as String] as? Int == 0
}
guard let info, let id = info[kCGWindowNumber as String] as? Int,
    let bounds = info[kCGWindowBounds as String] as? [String: Double]
else { exit(1) }
let rect = ["X", "Y", "Width", "Height"].map { String(Int(bounds[$0] ?? 0)) }
print(([String(id)] + rect).joined(separator: " "))
