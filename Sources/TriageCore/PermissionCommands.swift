import Foundation

/// The commands the Read-only auto preset runs without asking. Option safety is the guardrails' job and
/// has already been applied; this only decides which programs and subcommands count as reading.
enum ReadOnlyCommands {
    private static let programs: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "echo", "date", "which", "tree", "file", "stat", "grep", "rg",
        "diff", "basename", "dirname", "find",
    ]
    private static let gitRead: Set<String> = [
        "status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "ls-tree",
        "cat-file", "rev-list", "diff-tree", "merge-base", "grep", "name-rev", "count-objects",
    ]
    private static let ghRead: [String: Set<String>] = [
        "pr": ["view", "list", "diff", "checks", "status"], "issue": ["view", "list", "status"],
        "run": ["view", "list"], "repo": ["view"], "release": ["view", "list"], "auth": ["status"],
    ]

    static func isReadOnly(_ segment: [String]) -> Bool {
        guard let first = segment.first else { return false }
        let rest = Array(segment.dropFirst())
        switch first {
        case "git": return gitIsReadOnly(rest)
        case "gh": return ghIsReadOnly(rest)
        default: return programs.contains(first)
        }
    }

    private static func gitIsReadOnly(_ arguments: [String]) -> Bool {
        guard let subcommand = arguments.first else { return false }
        let rest = Array(arguments.dropFirst())
        // `--output=file` writes, and `-O<pager>` of `git grep` runs a program.
        if Guardrails.hasFlag(Guardrails.flagSet(rest), ["--output", "--open-files-in-pager", "-O"]) { return false }
        switch subcommand {
        case "branch":
            return rest.allSatisfy { ["-a", "-r", "-v", "-vv", "--list", "--show-current"].contains($0) }
        case "remote": return rest.isEmpty || rest == ["-v"]
        case "stash", "worktree": return rest.first == "list"
        case "tag": return rest.allSatisfy { ["-l", "--list", "-n"].contains($0) }
        case "config": return ["--get", "--list", "-l"].contains(rest.first ?? "")
        default: return gitRead.contains(subcommand)
        }
    }

    private static func ghIsReadOnly(_ arguments: [String]) -> Bool {
        // The noun and verb must lead: in `gh pr -R view comment` the verb is `comment`.
        guard arguments.count >= 2, !arguments[0].hasPrefix("-"), !arguments[1].hasPrefix("-"),
            let allowed = ghRead[arguments[0]]
        else { return false }
        return allowed.contains(arguments[1])
    }
}

public enum AgentsCommands {
    /// Command prefixes from the shell code blocks of an `AGENTS.md`, reduced to the words that name
    /// the command (`scripts/check.sh --fix` becomes `scripts/check.sh`).
    public static func extract(from markdown: String) -> [String] {
        var prefixes: [String] = []
        var language: String?
        var inside = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inside.toggle()
                language = inside ? String(trimmed.dropFirst(3)).lowercased() : nil
                continue
            }
            guard inside, ["", "bash", "sh", "zsh", "shell", "console"].contains(language ?? "") else { continue }
            var text = trimmed
            if text.hasPrefix("$ ") { text.removeFirst(2) }
            for marker in [" #", " <", " ["] {
                if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
            }
            guard !text.isEmpty, !text.hasPrefix("#"), let segments = ShellCommand.segments(text) else { continue }
            for segment in segments {
                guard Guardrails.permits(segment), !Guardrails.isOutward(segment),
                    let prefix = PermissionPolicy.prefix(of: segment)
                else { continue }
                let command = prefix.joined(separator: " ")
                if !prefixes.contains(command) { prefixes.append(command) }
            }
        }
        return prefixes
    }
}
