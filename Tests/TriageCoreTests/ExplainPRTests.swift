import Foundation
import Testing

@testable import TriageCore

private let repo = RepoRef(owner: "acme", name: "web")
private let head = "0123456789abcdef0123456789abcdef01234567"

@Suite struct ExplainPRNotePathAndFrontmatter {
    @Test func noteSitsInTheVaultAsRepoPrHead7() {
        let path = ExplainPR.notePath(
            vault: "/Users/g/Vault", fallbackFolder: "/tmp/fallback", repo: repo, number: 412, head: head)
        #expect(path == "/Users/g/Vault/acme-web-412-0123456.md")
    }

    @Test func anEmptyVaultFallsBackToTheAppFolder() {
        let path = ExplainPR.notePath(
            vault: "  ", fallbackFolder: "/tmp/fallback", repo: repo, number: 7, head: head)
        #expect(path == "/tmp/fallback/acme-web-7-0123456.md")
    }

    @Test func aGitLabGroupPathStaysOneFileName() {
        let mr = RepoRef(owner: "platform/infra", name: "deploy")
        #expect(ExplainPR.noteName(repo: mr, number: 58, head: head) == "platform-infra-deploy-58-0123456.md")
    }

    @Test func frontmatterCarriesPrHeadAndGenerated() {
        let text = ExplainPR.note(
            body: "\n# Title\n\nBody\n\n", repo: repo, number: 412, head: head,
            generated: Date(timeIntervalSince1970: 0))
        #expect(
            text == """
                ---
                pr: acme/web#412
                head: \(head)
                generated: 1970-01-01T00:00:00Z
                ---

                # Title

                Body

                """)
    }

    @Test func obsidianLinkUsesTheVaultNameAndTheNoteWithoutItsExtension() {
        let url = ExplainPR.obsidianURL(vault: "/Users/g/My Vault", note: "/Users/g/My Vault/acme-web-412-0123456.md")
        #expect(url?.absoluteString == "obsidian://open?vault=My%20Vault&file=acme-web-412-0123456")
        #expect(ExplainPR.obsidianURL(vault: "", note: "/x/a.md") == nil)
    }
}

@Suite struct ExplainPRStatusAndContract {
    private let record = ExplainPR.Record(head: head, note: "/n.md", at: Date(timeIntervalSince1970: 100))

    @Test func statusFollowsTheRecordAndTheHead() {
        #expect(ExplainPR.status(record: nil, currentHead: head, running: false) == .none)
        #expect(ExplainPR.status(record: record, currentHead: head, running: true) == .running)
        #expect(
            ExplainPR.status(record: record, currentHead: head, running: false) == .done(note: "/n.md", at: record.at))
        #expect(
            ExplainPR.status(record: record, currentHead: "ffffffff", running: false)
                == .stale(note: "/n.md", at: record.at))
    }

    @Test func theCallReadsTheLastStdoutLineAndTheStderrKind() {
        #expect(ExplainPR.arguments(number: 9) == ["explain-pr", "--pr", "9"])
        #expect(
            ExplainPR.reportedFile(stdout: "explaining…\nnote: x\n/a/b/pr-9-0123456.md\n") == "/a/b/pr-9-0123456.md")
        #expect(ExplainPR.reportedFile(stdout: "only progress\n") == nil)
        #expect(
            ExplainPR.failureMessage(stderr: "workbench: refused: pull request #9 is not open\n", status: 6)
                == "refused: pull request #9 is not open")
        #expect(ExplainPR.failureMessage(stderr: "", status: 1) == "Workbench exited with status 1.")
    }
}

/// Runs a stand-in `workbench` (a shell script) to check the call: where it runs, what it is given, what is written.
@Suite struct ExplainPRExecution {
    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("explain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fake(_ body: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent("workbench")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func writesTheNoteInTheVaultFromTheKeptFile() async throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkout = dir.appendingPathComponent("web")
        let vault = dir.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let script = try fake(
            """
            echo "explaining pull request #412"
            pwd > "\(dir.path)/cwd"
            echo "$@" > "\(dir.path)/args"
            printf '# Palette\\n\\nIt adds shortcuts.\\n' > "$PWD/pr-412-0123456.md"
            echo "$PWD/pr-412-0123456.md"
            """, in: dir)
        let out = try await ExplainPR.run(
            ExplainPR.Job(
                workbench: script, checkout: checkout.path, repo: repo, number: 412, head: head, vault: vault.path,
                fallbackFolder: dir.appendingPathComponent("fallback").path),
            now: Date(timeIntervalSince1970: 0))
        #expect(out.note == vault.appendingPathComponent("acme-web-412-0123456.md").path)
        let text = try String(contentsOfFile: out.note, encoding: .utf8)
        #expect(text.hasPrefix("---\npr: acme/web#412\nhead: \(head)\ngenerated: "))
        #expect(text.hasSuffix("---\n\n# Palette\n\nIt adds shortcuts.\n"))
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
        #expect(args == "explain-pr --pr 412\n")
        let cwd = try String(contentsOf: dir.appendingPathComponent("cwd"), encoding: .utf8)
        #expect(
            URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
                == checkout.resolvingSymlinksInPath())
    }

    @Test func aMovedHeadIsNamedByTheFileWorkbenchKept() async throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try fake(
            "printf '# T\\n' > \"$PWD/pr-5-aaaaaaa.md\"\necho \"$PWD/pr-5-aaaaaaa.md\"", in: dir)
        let out = try await ExplainPR.run(
            ExplainPR.Job(
                workbench: script, checkout: dir.path, repo: repo, number: 5, head: head, vault: "",
                fallbackFolder: dir.appendingPathComponent("fallback").path))
        #expect(out.head == "aaaaaaa")
        #expect(out.note.hasSuffix("/fallback/acme-web-5-aaaaaaa.md"))
    }

    @Test func aFailureCarriesWorkbenchsOwnMessage() async throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try fake("echo 'workbench: refused: pull request #5 is not open' >&2\nexit 6", in: dir)
        await #expect(throws: ExplainPR.Failure.failed("refused: pull request #5 is not open")) {
            try await ExplainPR.run(
                ExplainPR.Job(
                    workbench: script, checkout: dir.path, repo: repo, number: 5, head: head, vault: dir.path,
                    fallbackFolder: dir.path))
        }
    }

    @Test func aMissingCommandOrAnEmptyAnswerIsAnError() async throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: ExplainPR.Failure.self) {
            try await ExplainPR.run(
                ExplainPR.Job(
                    workbench: "/no/such/workbench", checkout: dir.path, repo: repo, number: 5, head: head,
                    vault: dir.path, fallbackFolder: dir.path))
        }
        let script = try fake("echo 'only progress'", in: dir)
        await #expect(throws: ExplainPR.Failure.noFile("only progress")) {
            try await ExplainPR.run(
                ExplainPR.Job(
                    workbench: script, checkout: dir.path, repo: repo, number: 5, head: head, vault: dir.path,
                    fallbackFolder: dir.path))
        }
    }

    @Test func workbenchIsFoundFromTheSettingOrTheKnownPlaces() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try fake("true", in: dir)
        #expect(ExplainPR.findWorkbench(setting: script) == script)
        #expect(ExplainPR.findWorkbench(setting: "/no/such/file") == nil)
        let bin = dir.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: script, toPath: bin.appendingPathComponent("workbench").path)
        #expect(ExplainPR.findWorkbench(setting: "", home: dir.path) == bin.appendingPathComponent("workbench").path)
    }
}

@Suite struct ExplainPRMockScenario {
    @Test func theScenarioSeedsRunningDoneAndStale() throws {
        let json = """
            {"github":{"viewer":"me","repos":["acme/web"]},"pullRequests":[
              {"repo":"acme/web","number":1,"title":"A","author":"me","createdHoursAgo":1},
              {"repo":"acme/web","number":2,"title":"B","author":"me","createdHoursAgo":1},
              {"repo":"acme/web","number":3,"title":"C","author":"me","createdHoursAgo":1}],
             "explains":[{"repo":"acme/web","number":1,"state":"running"},
              {"repo":"acme/web","number":2,"state":"done","hoursAgo":3},
              {"repo":"acme/web","number":3,"state":"stale"}]}
            """
        let world = try MockWorld(JSONDecoder().decode(MockScenario.self, from: Data(json.utf8)))
        #expect(world.explainRunning == ["acme/web#1"])
        let done = try #require(world.explainRecords["acme/web#2"])
        let stale = try #require(world.explainRecords["acme/web#3"])
        #expect(done.head.count == 40 && done.head != stale.head)
    }

    @Test func anUnknownPullRequestOrStateIsRejected() {
        for bad in [#"{"repo":"acme/web","number":9,"state":"done"}"#, #"{"repo":"acme/web","number":1,"state":"x"}"#] {
            let json = """
                {"github":{"viewer":"me","repos":[]},"pullRequests":[
                  {"repo":"acme/web","number":1,"title":"A","author":"me","createdHoursAgo":1}],"explains":[\(bad)]}
                """
            #expect(throws: MockError.self) {
                try MockWorld(JSONDecoder().decode(MockScenario.self, from: Data(json.utf8)))
            }
        }
    }
}

@Suite struct WorkbenchEnvironmentTests {
    @Test func putsTheToolFoldersAheadOfAGuiAppsMinimalPath() {
        let env = ExplainPR.workbenchEnvironment(base: ["PATH": "/usr/bin:/bin", "HOME": "/h"], home: "/h")
        let parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(parts.starts(with: ["/h/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]))
        #expect(parts.suffix(2) == ["/usr/bin", "/bin"])
        #expect(env["HOME"] == "/h")
    }

    @Test func doesNotRepeatAFolderAlreadyOnPath() {
        let env = ExplainPR.workbenchEnvironment(base: ["PATH": "/opt/homebrew/bin:/usr/bin"], home: "/h")
        let parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(parts.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    @Test func buildsAPathWhenThereIsNone() {
        #expect(ExplainPR.workbenchEnvironment(base: [:], home: "/h")["PATH"]?.hasPrefix("/h/.local/bin") == true)
    }
}

@Suite struct WorkbenchClaudeAccountTests {
    private func env(_ checkout: String, root: String = "~/rogal", base: [String: String] = [:]) -> [String: String] {
        ExplainPR.workbenchEnvironment(base: base, home: "/h", checkout: checkout, personalRoot: root)
    }

    @Test func aCheckoutUnderTheRootUsesThePersonalAccount() {
        #expect(env("/h/rogal/triage")["CLAUDE_CONFIG_DIR"] == "/h/.claude-personal")
        #expect(env("/h/rogal")["CLAUDE_CONFIG_DIR"] == "/h/.claude-personal")
    }

    @Test func anotherCheckoutUsesTheDefaultAccount() {
        #expect(env("/h/work/app", base: ["CLAUDE_CONFIG_DIR": "/x"])["CLAUDE_CONFIG_DIR"] == nil)
        #expect(env("/h/rogal-other/app")["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func anEmptyRootLeavesTheAccountAlone() {
        #expect(env("/h/rogal/x", root: "", base: ["CLAUDE_CONFIG_DIR": "/x"])["CLAUDE_CONFIG_DIR"] == "/x")
    }
}
