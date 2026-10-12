import Foundation

public enum PermissionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, readOnly, workflow

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: "Ask"
        case .readOnly: "Read-only auto"
        case .workflow: "Workflow auto"
        }
    }
    public var summary: String {
        switch self {
        case .ask: "Every tool call that no rule allows waits for you."
        case .readOnly: "Reading files and read-only git/gh commands run without asking."
        case .workflow: "Also the commands AGENTS.md names, and local git and swift build/test."
        }
    }
    public static let `default` = PermissionPreset.readOnly
}

public enum PermissionDecision: Equatable, Sendable {
    case allow(String)
    case prompt
}

/// Decides whether a tool call can run without asking. Pure: nothing is executed, and the only
/// file-system access is resolving paths against the thread's worktree.
///
/// Guardrails come first and cannot be overridden by a preset or a stored rule. A call that
/// is not understood completely is never auto-approved.
public struct PermissionPolicy: Equatable, Sendable {
    public var preset: PermissionPreset
    public var rules: [String]
    public var worktree: String
    public var workflowCommands: [String]

    public init(
        preset: PermissionPreset = .ask, rules: [String] = [], worktree: String = "", workflowCommands: [String] = []
    ) {
        self.preset = preset
        self.rules = rules
        self.worktree = worktree
        self.workflowCommands = workflowCommands
    }

    /// Builds the policy for one thread, reading the commands `AGENTS.md` names when the preset needs them.
    public static func make(
        preset: PermissionPreset, rules: [String], worktree: String, agentsMarkdown: String? = nil
    ) -> Self {
        var commands: [String] = []
        if preset == .workflow {
            let markdown =
                agentsMarkdown
                ?? (try? String(contentsOfFile: worktree + "/AGENTS.md", encoding: .utf8))
            commands = markdown.map(AgentsCommands.extract) ?? []
        }
        return Self(preset: preset, rules: rules, worktree: worktree, workflowCommands: commands)
    }

    // MARK: Deciding

    public func decide(tool: String, input: StreamJSON) -> PermissionDecision {
        guard pathsAreInsideWorktree(tool: tool, input: input) else { return .prompt }
        if tool == "Bash" { return decideBash(input["command"].text) }
        if rules.contains(tool) { return .allow("rule \(tool)") }
        if preset != .ask, Self.readOnlyTools.contains(tool) { return .allow(preset.title) }
        return .prompt
    }

    private func decideBash(_ command: String?) -> PermissionDecision {
        guard let command, let segments = ShellCommand.segments(command) else { return .prompt }
        var reasons: [String] = []
        for segment in segments.map(Self.withoutDotSlash) {
            guard let reason = allowance(for: segment) else { return .prompt }
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        return .allow(reasons.joined(separator: ", "))
    }

    private func allowance(for segment: [String]) -> String? {
        guard segmentIsAcceptable(segment) else { return nil }
        if let rule = rules.first(where: { Self.rule($0, matches: segment) }) { return "rule \(rule)" }
        guard preset != .ask else { return nil }
        if ReadOnlyCommands.isReadOnly(segment) { return preset.title }
        if preset == .workflow {
            let named = Self.workflowBuiltins + workflowCommands
            if named.contains(where: { Self.hasPrefix(segment, $0) }) { return preset.title }
        }
        return nil
    }

    // MARK: Remembering

    /// The rules "Always allow" would store for this call, or nil when it must keep prompting.
    public func rulesToRemember(tool: String, input: StreamJSON) -> [String]? {
        guard pathsAreInsideWorktree(tool: tool, input: input) else { return nil }
        guard tool == "Bash" else { return tool.isEmpty ? nil : [tool] }
        guard let command = input["command"].text, let segments = ShellCommand.segments(command) else { return nil }
        var rules: [String] = []
        for segment in segments {
            guard segmentIsAcceptable(segment), let prefix = Self.prefix(of: segment)
            else { return nil }
            let rule = "Bash(\(prefix.joined(separator: " ")):*)"
            if !rules.contains(rule) { rules.append(rule) }
        }
        return rules.isEmpty ? nil : rules
    }

    /// How many leading words identify "the same command" for a rule.
    static func prefix(of segment: [String]) -> [String]? {
        guard let program = segment.first, !program.isEmpty, !program.contains("="),
            !program.split(separator: "/").contains("..")
        else { return nil }
        let name = program.split(separator: "/").last.map(String.init) ?? program
        guard Guardrails.mayBeRemembered(program.contains("/") ? program : name) else { return nil }
        if Guardrails.subcommandPrograms.contains(name) {
            guard segment.count > 1, !segment[1].hasPrefix("-") else { return nil }
            if name == "gh" {
                // The verb is part of the rule: `gh pr comment` must not also allow `gh pr close`.
                guard segment.count > 2, !segment[2].hasPrefix("-") else { return nil }
                return Array(segment.prefix(3))
            }
            let runsScript = ["npm", "pnpm", "yarn"].contains(name) && segment[1] == "run"
            if runsScript, segment.count > 2, !segment[2].hasPrefix("-") { return Array(segment.prefix(3)) }
            return Array(segment.prefix(2))
        }
        if Guardrails.interpreters.contains(name) {
            guard segment.count > 1, !segment[1].hasPrefix("-") else { return nil }
            return Array(segment.prefix(2))
        }
        return [program]
    }

    /// `./scripts/check.sh` and `scripts/check.sh` are the same command.
    static func withoutDotSlash(_ segment: [String]) -> [String] {
        guard let first = segment.first, first.hasPrefix("./"), first.count > 2 else { return segment }
        return [String(first.dropFirst(2))] + segment.dropFirst()
    }

    // MARK: Rules

    static func rule(_ rule: String, matches segment: [String]) -> Bool {
        guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return false }
        let body = String(rule.dropFirst(5).dropLast())
        if body.hasSuffix(":*") {
            let prefix = body.dropLast(2).split(separator: " ").map(String.init)
            guard let program = prefix.first, Guardrails.mayBeRemembered(program) else { return false }
            return hasPrefix(segment, prefix.joined(separator: " "))
        }
        let words = body.split(separator: " ").map(String.init)
        guard let program = words.first, Guardrails.mayBeRemembered(program) else { return false }
        return segment == words
    }

    private static func hasPrefix(_ segment: [String], _ command: String) -> Bool {
        let words = command.split(separator: " ").map(String.init)
        return !words.isEmpty && segment.count >= words.count && Array(segment.prefix(words.count)) == words
    }

    // MARK: Paths

    private func pathsAreInsideWorktree(tool: String, input: StreamJSON) -> Bool {
        for key in ["file_path", "path", "notebook_path"] {
            if let path = input[key].text, !isInsideWorktree(path) { return false }
        }
        if tool == "Glob", let pattern = input["pattern"].text, !globIsInsideWorktree(pattern) { return false }
        if let glob = input["glob"].text, !globIsInsideWorktree(glob) { return false }
        return true
    }

    /// A glob that names files outside the worktree lists them even though no path argument looks wrong.
    private func globIsInsideWorktree(_ pattern: String) -> Bool {
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") || pattern.contains("..") && pattern.contains("{") { return false }
        if pattern.contains("{"), pattern.contains("{/") || pattern.contains(",/") || pattern.contains("~") {
            return false
        }
        guard pattern.hasPrefix("/") || pattern.hasPrefix("~") else { return true }
        let literal = components.prefix { !$0.contains(where: { "*?[{".contains($0) }) }
        let anchored = (pattern.hasPrefix("/") ? "/" : "") + literal.joined(separator: "/")
        return isInsideWorktree(anchored)
    }

    private func segmentIsAcceptable(_ segment: [String]) -> Bool {
        guard Guardrails.permits(segment), argumentsAreInsideWorktree(segment) else { return false }
        // `deno run -A https://host/x.ts` would run remote code under a rule for `deno run`.
        let name = segment.first?.split(separator: "/").last.map(String.init) ?? ""
        if Guardrails.interpreters.contains(name), segment.contains(where: { $0.contains("://") }) { return false }
        // `git checkout <path>` and `git checkout HEAD <path>` discard working-tree changes.
        guard segment.count > 1, segment[0] == "git", segment[1] == "checkout" else { return true }
        let words = segment.dropFirst(2).filter { !$0.hasPrefix("-") }
        let limit = segment.contains("-b") ? 2 : 1
        return words.count <= limit && !words.contains { Self.entryExists(resolve($0)) }
    }

    private func argumentsAreInsideWorktree(_ segment: [String]) -> Bool {
        for argument in segment.dropFirst() {
            for value in Self.pathCandidates(argument) where !valueIsInsideWorktree(value) { return false }
        }
        if let program = segment.first, program.contains("/"), !isInsideWorktree(program) { return false }
        return true
    }

    /// The parts of one argument that could be a path: the whole word, the value of `--opt=value`, and for a
    /// short-option cluster the value attached after the letters (`-f/etc/passwd`, `-rf/etc/passwd`).
    private static func pathCandidates(_ argument: String) -> [String] {
        if argument.hasPrefix("--") {
            guard let equals = argument.firstIndex(of: "=") else { return [] }
            return [String(argument[argument.index(after: equals)...])]
        }
        guard argument.hasPrefix("-"), argument != "-" else { return [argument] }
        var values = [String(argument.dropFirst(2))]
        if let slash = argument.firstIndex(where: { $0 == "/" || $0 == "~" }) {
            values.append(String(argument[slash...]))
        }
        return values
    }

    private func valueIsInsideWorktree(_ value: String) -> Bool {
        // `~user` is expanded by the shell to another home directory, which can't be resolved here.
        if value.hasPrefix("~"), value != "~", !value.hasPrefix("~/") { return false }
        // A glob through a directory can match entries (symlinks) this check never sees.
        if value.contains("/"), value.contains(where: { "*?[".contains($0) }) { return false }
        let looksLikePath =
            value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") || value.contains("/")
        let exists = !value.isEmpty && Self.entryExists(resolve(value))
        return !(looksLikePath || exists) || isInsideWorktree(value)
    }

    private func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        }
        return worktree + "/" + path
    }

    func isInsideWorktree(_ path: String) -> Bool {
        guard !worktree.isEmpty else { return false }
        if path.hasPrefix("~"), path != "~", !path.hasPrefix("~/") { return false }
        let root = Self.canonical(worktree)
        let target = Self.canonical(resolve(path))
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Whether something is at `path`, counting a dangling symlink, which `fileExists` would not.
    private static func entryExists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Resolves `path` one component at a time, the way the kernel does: a symlink is followed where it is
    /// met (dangling ones too, to where they would land), and `..` steps up from the *resolved* directory,
    /// so `link/../x` is not mistaken for a sibling of `link`. Missing components are kept as written.
    private static func canonical(_ path: String) -> String {
        var pending = path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                _ = resolved.popLast()
                continue
            }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                resolved.append(component)
                continue
            }
            links += 1
            // A loop never lands anywhere in the worktree.
            if links > 40 { return "/\u{0}symlink-loop" }
            if destination.hasPrefix("/") { resolved = [] }
            pending = destination.split(separator: "/").map(String.init) + pending
        }
        return "/" + resolved.joined(separator: "/")
    }

    // MARK: Presentation

    public static func summary(tool: String, input: StreamJSON) -> String {
        if let command = input["command"].text {
            let line = command.replacingOccurrences(of: "\n", with: " ")
            return "\(tool) `\(line.count > 120 ? String(line.prefix(120)) + "…" : line)`"
        }
        for key in ["file_path", "path", "notebook_path", "url", "pattern"] {
            if let value = input[key].text { return "\(tool) \(value)" }
        }
        return tool
    }

    static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob"]
    static let workflowBuiltins = [
        "swift build", "swift test", "git add", "git commit", "git fetch", "git switch", "git merge", "git rebase",
    ]
}
