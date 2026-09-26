// Drive Triage's main window through the Accessibility API. The terminal needs Accessibility permission. Used by /verify.
//   swift scripts/ax.swift                  list what's on screen: role <tab> label
//   swift scripts/ax.swift press "Dismiss"  press the first button, or select the first row, whose label starts with that
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

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.rogal.triage").first else {
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
    let result =
        hit.role == "AXRow"
        ? AXUIElementSetAttributeValue(hit.element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        : AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
    print(result == .success ? "pressed \(hit.role) \(hit.label)" : "failed (\(result.rawValue)) on \(hit.label)")
} else {
    for item in found {
        print("\(item.role)\t\(item.label.replacingOccurrences(of: "\n", with: " ").prefix(100))")
    }
}
