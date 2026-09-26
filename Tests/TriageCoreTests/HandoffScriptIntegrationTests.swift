import Foundation
import Testing
@testable import TriageCore

/// Runs the generated handoff script against throwaway git repos (a bare "origin" + a clone), with the
/// harness replaced by `cat` and the trailing interactive shells replaced by exit, so it finishes on its own.
@Suite(.serialized) struct HandoffScriptIntegrationTests {
    let root: URL
    let checkout: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("triage-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin.git").path
        checkout = root.appendingPathComponent("repo").path
        try sh("""
        git init -q --bare -b main '\(origin)'
        git clone -q '\(origin)' '\(checkout)' 2>/dev/null
        cd '\(checkout)'
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
        git push -q origin main
        git checkout -q -b feature/fix-ci
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip
        git push -q origin feature/fix-ci
        git checkout -q main
        git branch -q -D feature/fix-ci
        """)
    }

    @discardableResult
    func sh(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", script]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func runHandoff(branch: String) throws -> String {
        let promptFile = root.appendingPathComponent("prompt.md")
        try "PROMPT-BODY".write(to: promptFile, atomically: true, encoding: .utf8)
        let plan = HandoffPlan(repo: RepoRef(owner: "acme", name: "repo"), prNumber: 42, branch: branch,
                               checkout: checkout, promptFile: promptFile.path, harnessCommand: "cat {prompt_file}")
        let script = Handoff.script(plan)
            .replacingOccurrences(of: "#!/bin/zsh -il\n", with: "")
            .replacingOccurrences(of: "exec zsh -il", with: "exit 0")
        let file = root.appendingPathComponent("handoff.command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        return try sh("zsh -f '\(file.path)'")
    }

    @Test func createsWorktreeFromOriginAndStartsHarness() throws {
        let out = try runHandoff(branch: "feature/fix-ci")
        let wt = Handoff.worktreePath(checkout: checkout, pr: 42)
        #expect(out.contains("creating worktree"), "\(out)")
        #expect(out.contains("PROMPT-BODY"), "\(out)")
        #expect(try sh("git -C '\(wt)' rev-parse --abbrev-ref HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "feature/fix-ci")
    }

    @Test func reusesAnExistingWorktree() throws {
        _ = try runHandoff(branch: "feature/fix-ci")
        let second = try runHandoff(branch: "feature/fix-ci")
        #expect(!second.contains("creating worktree"), "\(second)")
        #expect(second.contains("PROMPT-BODY"), "\(second)")
    }

    @Test func usesTheCheckoutThatAlreadyHasTheBranch() throws {
        try sh("cd '\(checkout)' && git checkout -q feature/fix-ci")
        let out = try runHandoff(branch: "feature/fix-ci")
        #expect(out.contains("already checked out"), "\(out)")
        #expect(out.contains("PROMPT-BODY"), "\(out)")
        #expect(!FileManager.default.fileExists(atPath: Handoff.worktreePath(checkout: checkout, pr: 42)))
    }
}
