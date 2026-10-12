import Foundation
import Testing

@testable import TriageCore

private func temporaryProject() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func settingsText(_ project: URL) throws -> String {
    try String(contentsOf: project.appendingPathComponent(".claude/settings.local.json"), encoding: .utf8)
}

@Suite struct RepoPermissionSettingsTests {
    @Test func createsTheFileAndDirectory() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        try RepoPermissionSettings.add(rules: ["Bash(swift test:*)"], toProjectAt: project.path)
        let json = try JSONSerialization.jsonObject(with: Data(settingsText(project).utf8)) as? [String: Any]
        let allow = (json?["permissions"] as? [String: Any])?["allow"] as? [String]
        #expect(allow == ["Bash(swift test:*)"])
    }

    @Test func keepsExistingContentAndOrder() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let directory = project.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = """
            {
              "zeta": {"keep": [1, 2.50, true, null, "caf\\u00e9"]},
              "permissions": {
                "deny": ["Bash(rm:*)"],
                "allow": ["Read", "Bash(git status:*)"]
              },
              "alpha": "last"
            }
            """
        try original.write(
            to: directory.appendingPathComponent("settings.local.json"), atomically: true, encoding: .utf8)
        try RepoPermissionSettings.add(
            rules: ["Bash(git status:*)", "Bash(swift test:*)"], toProjectAt: project.path)
        let text = try settingsText(project)
        let order = ["\"zeta\"", "\"permissions\"", "\"deny\"", "\"allow\"", "\"alpha\""].compactMap {
            text.range(of: $0)?.lowerBound
        }
        #expect(order.count == 5)
        #expect(order == order.sorted())
        #expect(text.contains("2.50"))
        #expect(text.contains("café"))
        #expect(text.contains("\"Bash(rm:*)\""))
        #expect(text.components(separatedBy: "Bash(git status:*)").count == 2, "no duplicate rule")
        #expect(text.contains("\"Bash(swift test:*)\""))
        let readIndex = try #require(text.range(of: "\"Read\"")).lowerBound
        let addedIndex = try #require(text.range(of: "\"Bash(swift test:*)\"")).lowerBound
        #expect(readIndex < addedIndex)
    }

    @Test func isIdempotent() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        try RepoPermissionSettings.add(rules: ["Edit"], toProjectAt: project.path)
        let first = try settingsText(project)
        try RepoPermissionSettings.add(rules: ["Edit"], toProjectAt: project.path)
        #expect(try settingsText(project) == first)
    }

    @Test(arguments: ["{ not json", "[1, 2]", "{\"permissions\": []}", "{\"permissions\": {\"allow\": \"Read\"}}"])
    func leavesUnexpectedFilesUntouched(content: String) throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let directory = project.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.local.json")
        try content.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: WorkbenchError.self) {
            try RepoPermissionSettings.add(rules: ["Edit"], toProjectAt: project.path)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == content)
    }

    @Test func roundTripsEscapesAndSurrogatePairs() throws {
        let source = "{\"a\": \"line\\nbreak \\\"q\\\" \\ud83d\\ude00 \\/\", \"n\": -0.5e3, \"e\": {}, \"l\": []}"
        let parsed = try #require(OrderedJSON.parse(source))
        #expect(OrderedJSON.parse(parsed.serialized()) == parsed)
        #expect(parsed.serialized().contains("😀"))
        #expect(OrderedJSON.parse("{\"a\": 1,}") == nil)
        #expect(OrderedJSON.parse("{\"a\": 1} trailing") == nil)
    }
}

@Suite struct WorkbenchPolicyModelTests {
    @Test func catalogFromBeforePermissionsStillLoads() throws {
        let project = UUID(), thread = UUID(), session = UUID()
        let json = """
            {"projects":[{"id":"\(project)","name":"app","path":"/tmp/app"}],
             "threads":[{"id":"\(thread)","projectID":"\(project)","sessionID":"\(session)","title":"t",
                         "worktree":"/tmp/app-wt","branch":"b","state":"idle","hasSession":true,"messages":[]}]}
            """
        let catalog = try JSONDecoder().decode(WorkbenchCatalog.self, from: Data(json.utf8))
        #expect(catalog.projects[0].preset == .readOnly)
        #expect(catalog.projects[0].rules.isEmpty)
        #expect(catalog.threads[0].preset == nil)
        #expect(catalog.threads[0].rules.isEmpty)
    }

    @Test func presetsAndRulesRoundTrip() throws {
        var project = WorkbenchProject(name: "app", path: "/tmp/app", preset: .workflow, rules: ["Bash(swift test:*)"])
        project.rules.append("Edit")
        let thread = WorkbenchThread(
            projectID: project.id, title: "t", worktree: "/tmp/wt", branch: "b", preset: .ask, rules: ["Read"])
        let catalog = WorkbenchCatalog(projects: [project], threads: [thread])
        let decoded = try JSONDecoder().decode(WorkbenchCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(decoded == catalog)
    }

    @Test func newProjectsStartReadOnlyAndThreadsOverrideThem() {
        let project = WorkbenchProject(name: "app", path: "/tmp/app", rules: ["Bash(git status:*)"])
        #expect(project.preset == .readOnly)
        var thread = WorkbenchThread(
            projectID: project.id, title: "t", worktree: "/tmp/wt", branch: "b", rules: ["Edit"])
        #expect(thread.policy(in: project).preset == .readOnly)
        #expect(thread.policy(in: project).rules == ["Bash(git status:*)", "Edit"])
        thread.preset = .ask
        #expect(thread.policy(in: project).preset == .ask)
        #expect(thread.policy(in: nil).preset == .ask)
        thread.preset = nil
        #expect(thread.policy(in: nil).preset == .readOnly)
    }
}
