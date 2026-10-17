// Drive Triage's main window through the Accessibility API. The terminal needs Accessibility permission. Used by /verify.
//   swift scripts/ax.swift                  list what's on screen: role <tab> label
//   swift scripts/ax.swift press "Dismiss"  press the first button, or select the first row, whose label starts with that
//   swift scripts/ax.swift resize 1440 900  set the main window's size in points (scripts/verify.sh)
//   TRIAGE_PID=<pid> swift scripts/ax.swift ...  drive that process, not the installed app (scripts/verify.sh)
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func ownText(_ element: AXUIElement) -> String {
    let parts = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
        attribute(element, $0) as? String
    }
    return parts.first { !$0.isEmpty } ?? ""
}
/// A row or an icon+text button is labelled by the text inside it, so it can be pressed by what it shows.
func text(_ element: AXUIElement, depth: Int = 0) -> String {
    let own = ownText(element)
    guard own.isEmpty, depth < 6 else { return own }
    return children(element).map { text($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: " ")
}

struct Found {
    let element: AXUIElement
    let role: String
    let label: String
}
let pressable: Set<String> = [
    "AXButton", "AXRow", "AXMenuButton", "AXLink", "AXCheckBox", "AXTextField", "AXPopUpButton",
]
func walk(_ element: AXUIElement, into found: inout [Found]) {
    for child in children(element) {
        let role = attribute(child, kAXRoleAttribute) as? String ?? ""
        if pressable.contains(role) {
            found.append(Found(element: child, role: role, label: text(child)))
            if role == "AXRow" { continue }
        }
        walk(child, into: &found)
    }
}

// TRIAGE_PID drives that one process, whatever its bundle id: scripts/verify.sh's throwaway build has its own id and
// runs next to the installed app, which this must never press buttons in. Without it, the installed app, as before.
let app: NSRunningApplication
if let raw = ProcessInfo.processInfo.environment["TRIAGE_PID"] {
    guard let pid = Int32(raw), let byPID = NSRunningApplication(processIdentifier: pid) else {
        FileHandle.standardError.write(Data("No process \"\(raw)\" (TRIAGE_PID)\n".utf8))
        exit(1)
    }
    app = byPID
} else if let installed = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.rogal.triage").first {
    app = installed
} else {
    FileHandle.standardError.write(Data("Triage isn't running\n".utf8))
    exit(1)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("No Accessibility permission for this terminal\n".utf8))
    exit(1)
}
let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]
guard let window = windows?.first(where: { attribute($0, kAXTitleAttribute) as? String == "Triage" }) ?? windows?.first
else {
    FileHandle.standardError.write(Data("No Triage window\n".utf8))
    exit(1)
}
var found: [Found] = []
walk(window, into: &found)

let args = CommandLine.arguments.dropFirst()
if args.first == "press", let target = args.dropFirst().first {
    guard let hit = found.first(where: { $0.label == target }) ?? found.first(where: { $0.label.hasPrefix(target) })
    else {
        FileHandle.standardError.write(Data("Nothing labelled \"\(target)\"\n".utf8))
        exit(1)
    }
    // TRIAGE_REFUSE: a regex the resolved label must not match. Checked here, not on `target`, because the match
    // above is by prefix: "Expl" resolves to "Explain & propose fix". Set by scripts/verify.sh.
    let refuse = ProcessInfo.processInfo.environment["TRIAGE_REFUSE"]
    if let refuse, hit.label.range(of: refuse, options: .regularExpression) != nil {
        FileHandle.standardError.write(Data("Refused: \"\(target)\" is \"\(hit.label)\"\n".utf8))
        exit(1)
    }
    let result =
        hit.role == "AXRow"
        ? AXUIElementSetAttributeValue(hit.element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        : AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
    guard result == .success else {
        FileHandle.standardError.write(Data("failed (\(result.rawValue)) on \(hit.label)\n".utf8))
        exit(1)
    }
    print("pressed \(hit.role) \(hit.label)")
} else if args.first == "resize" {
    let sizes = args.dropFirst().compactMap { Int($0) }.filter { $0 > 0 }
    guard args.count == 3, sizes.count == 2 else {
        FileHandle.standardError.write(Data("resize needs two positive integers: <width> <height>\n".utf8))
        exit(1)
    }
    var size = CGSize(width: sizes[0], height: sizes[1])
    guard let value = AXValueCreate(.cgSize, &size) else { exit(1) }
    let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    guard result == .success else {
        FileHandle.standardError.write(Data("resize failed (\(result.rawValue))\n".utf8))
        exit(1)
    }
    print("resized to \(sizes[0])x\(sizes[1])")
} else {
    for item in found {
        print("\(item.role)\t\(item.label.replacingOccurrences(of: "\n", with: " ").prefix(100))")
    }
}
