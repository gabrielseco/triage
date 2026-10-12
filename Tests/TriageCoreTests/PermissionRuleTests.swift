import Foundation
import Testing

@testable import TriageCore

@Suite struct PermissionRuleTests {
    @Test func globToolsAndGlobArgumentsStayInsideTheWorktree() throws {
        let tree = try Worktree()
        defer { tree.remove() }
        let policy = tree.policy(.readOnly)
        func glob(_ pattern: String, key: String = "pattern", tool: String = "Glob") -> PermissionDecision {
            policy.decide(tool: tool, input: .object([key: .string(pattern)]))
        }
        for pattern in ["/etc/*", "../../*", "~/.ssh/*", "~root/*", "src/../../*", tree.path + "/../*"] {
            #expect(glob(pattern) == .prompt, "\(pattern)")
        }
        for pattern in ["**/*.swift", "src/*.swift", tree.path + "/**/*.swift"] {
            #expect(glob(pattern) == .allow("Read-only auto"), "\(pattern)")
        }
        #expect(glob("/etc/*", key: "glob", tool: "Grep") == .prompt)
        #expect(glob("*.swift", key: "glob", tool: "Grep") == .allow("Read-only auto"))
        #expect(policy.decide(tool: "Read", input: file("~root/.zshrc")) == .prompt)
    }

    @Test func rulesCoverTheVerbShownAndNothingBroader() throws {
        let tree = try Worktree()
        defer { tree.remove() }
        let policy = tree.policy(.ask)
        let comment = try #require(
            policy.rulesToRemember(tool: "Bash", input: bash("gh pr comment 1 --body hi")))
        #expect(comment == ["Bash(gh pr comment:*)"])
        let learned = tree.policy(.ask, rules: comment)
        #expect(learned.decide(tool: "Bash", input: bash("gh pr comment 2 --body x")) != .prompt)
        #expect(learned.decide(tool: "Bash", input: bash("gh pr close 2")) == .prompt)
        #expect(policy.rulesToRemember(tool: "Bash", input: bash("gh pr -R x comment 1")) == nil)
        #expect(policy.rulesToRemember(tool: "Bash", input: bash("npx sh -c ls")) == nil)
        #expect(policy.rulesToRemember(tool: "Bash", input: bash("uv run pytest")) == nil)
        // A rule that would let a branch switch also covers `git checkout`, but not a path restore.
        let checkout = tree.policy(.ask, rules: ["Bash(git checkout:*)"])
        #expect(checkout.decide(tool: "Bash", input: bash("git checkout feature/x")) != .prompt)
        #expect(checkout.decide(tool: "Bash", input: bash("git checkout -b new main")) != .prompt)
        #expect(checkout.decide(tool: "Bash", input: bash("git checkout HEAD notes.txt")) == .prompt)
    }

    @Test func rememberedRulesAreDerivedNarrowly() throws {
        let tree = try Worktree()
        defer { tree.remove() }
        let policy = tree.policy(.ask)
        func rules(_ command: String) -> [String]? { policy.rulesToRemember(tool: "Bash", input: bash(command)) }
        #expect(rules("swift test --filter X") == ["Bash(swift test:*)"])
        #expect(rules("git status") == ["Bash(git status:*)"])
        #expect(rules("npm run build -- --watch") == ["Bash(npm run build:*)"])
        #expect(rules("python3 scripts/task-goal.py check x") == ["Bash(python3 scripts/task-goal.py:*)"])
        #expect(rules("scripts/check.sh --fix") == ["Bash(scripts/check.sh:*)"])
        #expect(rules("ls -la | head") == ["Bash(ls:*)", "Bash(head:*)"])
        #expect(rules("python3 -c 'import os'") == nil)
        #expect(rules("node -e 1") == nil)
        #expect(rules("git -c x=y log") == nil)
        #expect(rules("rm -rf x") == nil)
        #expect(rules("git push --force") == nil)
        #expect(rules("ls $(pwd)") == nil)
        #expect(rules("cat /etc/passwd") == nil)
        #expect(rules("FOO=1 ls") == nil)
        for wrapper in ["time rm x", "command ls", "nice ls", "timeout 5 ls", "sed -n p x", "cd x", "do ls", "tee x"] {
            #expect(rules(wrapper) == nil, "\(wrapper) must not be remembered")
        }
        #expect(rules("some-unknown-tool --flag") == nil)
        #expect(rules("find . -name x") == ["Bash(find:*)"])
        #expect(policy.rulesToRemember(tool: "Edit", input: file(tree.path + "/notes.txt")) == ["Edit"])
        #expect(policy.rulesToRemember(tool: "Edit", input: file("/etc/hosts")) == nil)
        for command in ["swift test", "git status", "ls -la | head", "scripts/check.sh --fix"] {
            let remembered = try #require(rules(command))
            #expect(!remembered.contains("Bash"), "never a blanket rule")
            let learned = tree.policy(.ask, rules: remembered)
            #expect(learned.decide(tool: "Bash", input: bash(command)) != .prompt, "\(command)")
        }
    }

    @Test func agentsMarkdownYieldsCommandPrefixes() {
        let markdown = """
            # Project

            ```bash
            scripts/check.sh         # what CI runs
            scripts/check.sh --fix   # auto-format first
            scripts/snap.sh out.png  # screenshot
            rm -rf .build
            git push --force
            sudo make install
            ```

            ```bash
            python3 scripts/task-event.py pr-created <slug> --pr <number>
            gh pr merge --merge
            swift test --filter Foo
            ```

            ```json
            {"command": "scripts/not-a-command.sh"}
            ```
            """
        let commands = AgentsCommands.extract(from: markdown)
        #expect(commands.contains("scripts/check.sh"))
        #expect(commands.contains("scripts/snap.sh"))
        #expect(commands.contains("python3 scripts/task-event.py"))
        #expect(commands.contains("swift test"))
        #expect(!commands.contains { $0.hasPrefix("rm") || $0.hasPrefix("sudo") || $0.contains("push") })
        #expect(!commands.contains { $0.contains("merge") || $0.contains("not-a-command") })
        #expect(commands.filter { $0 == "scripts/check.sh" }.count == 1)
        let outward = AgentsCommands.extract(
            from: "```bash\ngit push origin HEAD\ngh pr create --fill\ngh pr checks\nuv run pytest\nnpx tsc\n```")
        #expect(outward == ["gh pr checks"], "pushing, posting and wrapper commands are never taken from AGENTS.md")
    }

    @Test func workflowPolicyReadsAgentsFromTheWorktree() throws {
        let tree = try Worktree()
        defer { tree.remove() }
        try "```bash\nscripts/check.sh\n```\n".write(
            to: tree.url.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let policy = PermissionPolicy.make(preset: .workflow, rules: [], worktree: tree.path)
        #expect(policy.workflowCommands == ["scripts/check.sh"])
        #expect(PermissionPolicy.make(preset: .readOnly, rules: [], worktree: tree.path).workflowCommands.isEmpty)
    }

    @Test func summaryNamesTheCommandOrPath() {
        #expect(PermissionPolicy.summary(tool: "Bash", input: bash("git status")) == "Bash `git status`")
        #expect(PermissionPolicy.summary(tool: "Read", input: file("/a/b")) == "Read /a/b")
        #expect(PermissionPolicy.summary(tool: "Task", input: .object([:])) == "Task")
    }

    @Test func danglingSymlinkIsFollowedToItsRealTarget() throws {
        let tree = try Worktree()
        defer { tree.remove() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            at: tree.url.appendingPathComponent("dang"), withDestinationURL: missing.appendingPathComponent("x"))
        try FileManager.default.createSymbolicLink(
            atPath: tree.url.appendingPathComponent("rel").path,
            withDestinationPath: "../" + missing.lastPathComponent + "/y")
        let policy = tree.policy(
            .ask, rules: ["Bash(touch:*)", "Bash(cp:*)", "Bash(mkdir:*)", "Bash(mv:*)", "Write", "Edit"])
        for command in [
            "touch dang", "cp notes.txt dang", "mkdir dang", "mkdir -p dang/a/b", "mv notes.txt dang", "touch rel",
        ] {
            #expect(policy.decide(tool: "Bash", input: bash(command)) == .prompt, "\(command)")
        }
        for tool in ["Write", "Edit"] {
            #expect(policy.decide(tool: tool, input: file(tree.path + "/dang")) == .prompt)
            #expect(policy.decide(tool: tool, input: file("dang")) == .prompt)
        }
        #expect(policy.decide(tool: "Bash", input: bash("touch fresh.txt")) != .prompt)
        #expect(FileManager.default.fileExists(atPath: missing.path) == false)
    }

    @Test func parentTraversalAfterASymlinkStepsUpFromTheLinkTarget() throws {
        let tree = try Worktree()
        defer { tree.remove() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-" + UUID().uuidString).appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: outside.deletingLastPathComponent().deletingLastPathComponent())
        }
        try FileManager.default.createSymbolicLink(
            at: tree.url.appendingPathComponent("outdir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            atPath: tree.url.appendingPathComponent("loop").path, withDestinationPath: "loop")
        let policy = tree.policy(.readOnly, rules: ["Bash(touch:*)", "Bash(cat:*)", "Write", "Read"])
        #expect(policy.decide(tool: "Read", input: file("outdir/../secret")) == .prompt)
        #expect(policy.decide(tool: "Write", input: file(tree.path + "/outdir/../secret")) == .prompt)
        for command in ["cat outdir/../secret", "touch outdir/../secret", "cat loop/x"] {
            #expect(policy.decide(tool: "Bash", input: bash(command)) == .prompt, "\(command)")
        }
        #expect(policy.decide(tool: "Bash", input: bash("cat src/../notes.txt")) != .prompt)
    }

    @Test func bracesInGlobPatternsAndDotSlashScripts() throws {
        let tree = try Worktree()
        defer { tree.remove() }
        let policy = tree.policy(.readOnly)
        for pattern in ["{/etc/*,src/*}", "{../*,x}", "src/{a,~/.ssh}/*"] {
            #expect(policy.decide(tool: "Glob", input: .object(["pattern": .string(pattern)])) == .prompt, "\(pattern)")
        }
        #expect(policy.decide(tool: "Glob", input: .object(["pattern": .string("src/**/*.{swift,md}")])) != .prompt)
        let workflow = tree.policy(.workflow, commands: ["scripts/check.sh"])
        #expect(workflow.decide(tool: "Bash", input: bash("./scripts/check.sh --fix")) != .prompt)
        #expect(workflow.decide(tool: "Bash", input: bash("./scripts/other.sh")) == .prompt)
    }
}
