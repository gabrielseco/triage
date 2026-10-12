import Foundation

/// Commands that always ask, whatever preset or stored rule would otherwise allow them.
///
/// Rather than recognising every dangerous spelling, this works from what a program can do:
/// programs that run other programs or can't be reasoned about never run unattended, options are
/// matched including their unique abbreviations, and rules can only name programs that were vetted.
enum Guardrails {
    /// Wrappers, shells, shell keywords, and tools that execute, escalate, delete, or leave the worktree.
    static let neverAuto: Set<String> = [
        "rm", "rmdir", "sudo", "su", "doas", "dd", "mkfs", "shutdown", "reboot", "osascript", "eval", "exec", "sh",
        "bash", "zsh", "fish", "xargs", "env", "nohup", "ssh", "scp", "sftp", "curl", "wget", "chmod", "chown",
        "kill", "killall", "pkill", "launchctl", "defaults", "source", ".", "time", "command", "builtin", "nice",
        "timeout", "stdbuf", "watch", "parallel", "caffeinate", "open", "say", "cd", "pushd", "popd", "sed", "awk",
        "gawk", "perl", "do", "then", "else", "elif", "fi", "done", "if", "while", "until", "for", "case", "esac",
        "function", "!", "{", "}", "[[", "trap", "alias", "export", "unset", "set", "tee", "npx", "bunx", "pnpx",
    ]

    /// Programs that take a subcommand: a rule names the program and the subcommand.
    static let subcommandPrograms: Set<String> = [
        "git", "gh", "swift", "npm", "pnpm", "yarn", "cargo", "make", "xcodebuild", "bun", "uv", "just",
    ]
    /// Subcommands that run whatever program they are handed, so a rule or preset must never cover them.
    private static let executingSubcommands: [String: Set<String>] = [
        "uv": ["run", "tool", "x"], "npm": ["exec", "x", "create", "init"], "pnpm": ["exec", "dlx", "create"],
        "yarn": ["exec", "dlx", "create"], "bun": ["x", "create"],
    ]
    /// Programs that run a script: a rule names the program and the script.
    static let interpreters: Set<String> = ["python", "python3", "node", "ruby", "deno", "tsx"]
    /// Plain programs "Always allow" may store a rule for. Anything else can be allowed once, never remembered.
    static let rememberable: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "echo", "date", "which", "tree", "file", "stat", "grep", "rg",
        "diff", "basename", "dirname", "find", "sort", "cut", "tr", "touch", "mkdir", "cp", "mv",
        "swift-format", "swiftlint",
    ]

    /// Whether a rule may name `program` at all, checked again when a stored rule is matched.
    static func mayBeRemembered(_ program: String) -> Bool {
        if program.contains("/") { return true }  // a script in the worktree; its path is checked separately
        guard !neverAuto.contains(program) else { return false }
        return subcommandPrograms.contains(program) || interpreters.contains(program)
            || rememberable.contains(program)
    }

    static func permits(_ segment: [String]) -> Bool {
        guard let first = segment.first, !first.contains("=") else { return false }
        let program = first.split(separator: "/").last.map(String.init) ?? first
        guard !neverAuto.contains(program) else { return false }
        let arguments = Array(segment.dropFirst())
        guard optionsAreSafe(program, arguments) else { return false }
        let verb = arguments.first { !$0.hasPrefix("-") }
        if let verb, executingSubcommands[program]?.contains(verb) == true { return false }
        switch program {
        case "git": return gitIsSafe(arguments)
        case "gh": return ghIsSafe(arguments)
        default: return true
        }
    }

    // MARK: Options

    /// Option names in `arguments`, with `--name=value` reduced to `--name` and a cluster such as `-fu`
    /// also contributing `-f` and `-u`, so `git push -fu` is seen as a force push.
    static func flagSet(_ arguments: [String]) -> Set<String> {
        var result = Set<String>()
        for argument in arguments where argument.hasPrefix("-") && argument != "-" && argument != "--" {
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            result.insert(name)
            if !name.hasPrefix("--") {
                for letter in name.dropFirst() { result.insert("-\(letter)") }
            }
        }
        return result
    }

    /// Whether any flag is one of `names`, counting unique abbreviations of long options
    /// (`--har` for `--hard`), which git, gh and ripgrep accept.
    static func hasFlag(_ flags: Set<String>, _ names: [String]) -> Bool {
        flags.contains { flag in
            names.contains { name in
                flag == name
                    || (flag.hasPrefix("--") && name.hasPrefix("--") && (name.hasPrefix(flag) || flag.hasPrefix(name)))
            }
        }
    }

    /// Options that write files, run a program, or follow symlinks out of the worktree.
    private static let blockedOptions: [String: [String]] = [
        "rg": ["--pre", "--hostname-bin", "--follow", "-L"], "grep": ["-R", "-S", "--dereference-recursive"],
        "ls": ["-L", "-H"], "tree": ["-o", "--output", "-l"], "sort": ["-o", "--output", "--compress-program"],
        "file": ["-C", "--compile"], "cp": ["-L", "-H"],
    ]

    private static func optionsAreSafe(_ program: String, _ arguments: [String]) -> Bool {
        if program == "find" {
            // find writes with -exec/-delete/-fprint and walks through symlinks with -L, -H and -follow.
            let blocked: Set<String> = [
                "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls", "-L",
                "-H", "-follow",
            ]
            return blocked.isDisjoint(with: arguments)
        }
        guard let names = blockedOptions[program] else { return true }
        return !hasFlag(flagSet(arguments), names)
    }

    // MARK: git

    private static func gitIsSafe(_ arguments: [String]) -> Bool {
        // Global options (-c, -C, --git-dir, --exec-path) can redirect or run arbitrary programs.
        guard let subcommand = arguments.first, !subcommand.hasPrefix("-") else { return false }
        let rest = Array(arguments.dropFirst())
        let flags = flagSet(rest)
        if alwaysAsk.contains(subcommand) { return false }
        let runsPrograms = ["--exec", "--upload-pack", "--receive-pack", "--exec-path", "--ext-diff", "--textconv"]
        if hasFlag(flags, runsPrograms + ["--pathspec-from-file"]) { return false }
        if let verbs = askForVerbs[subcommand], verbs.contains(rest.first ?? "") { return false }
        if let names = askForFlags[subcommand], hasFlag(flags, names) { return false }
        return subcommandIsSafe(subcommand, rest, flags: flags)
    }

    private static func subcommandIsSafe(_ subcommand: String, _ rest: [String], flags: Set<String>) -> Bool {
        switch subcommand {
        case "push": return pushIsSafe(rest, flags: flags)
        case "fetch", "pull": return !hasFlag(flags, ["-f", "--force"]) && !rest.contains { $0.hasPrefix("+") }
        case "checkout": return !rest.contains("--") && !rest.contains(".")
        case "restore": return hasFlag(flags, ["--staged", "-S"]) && !hasFlag(flags, ["--worktree", "-W"])
        case "config": return ["--get", "--get-all", "--list", "-l"].contains(rest.first ?? "")
        default: return true
        }
    }

    /// Commands that delete history or data, or can execute configured programs.
    private static let alwaysAsk: Set<String> = [
        "clean", "filter-branch", "filter-repo", "gc", "prune", "update-ref", "reflog", "replace", "rm",
        "submodule", "bisect", "difftool", "mergetool", "daemon", "instaweb", "fast-import", "gui", "read-tree",
        "checkout-index",
    ]
    private static let askForVerbs: [String: Set<String>] = [
        "stash": ["drop", "clear"], "worktree": ["remove", "prune", "move"],
        "remote": ["remove", "rm", "set-url", "rename"],
    ]
    private static let askForFlags: [String: [String]] = [
        "reset": ["--hard", "--merge", "--keep"],
        "branch": ["-D", "-d", "-m", "-M", "-f", "--delete", "--move", "--force"],
        "tag": ["-d", "-f", "--delete", "--force"],
        "checkout": ["-f", "-B", "--force"],
        "switch": ["-f", "-C", "--force", "--discard-changes", "--force-create"],
        "rebase": ["-x", "-i", "--interactive"],
    ]

    private static func pushIsSafe(_ rest: [String], flags: Set<String>) -> Bool {
        let risky = ["-f", "-d", "--force", "--force-with-lease", "--force-if-includes", "--delete", "--mirror"]
        let refspec = rest.contains { !$0.hasPrefix("-") && ($0.hasPrefix("+") || $0.hasPrefix(":")) }
        return !hasFlag(flags, risky + ["--prune"]) && !refspec
    }

    // MARK: gh

    /// Commands that act outside the checkout (publish, post, or change GitHub). `AGENTS.md` naming one is
    /// not enough to run it unattended.
    static func isOutward(_ segment: [String]) -> Bool {
        switch segment.first {
        case "git": return ["push", "send-email"].contains(segment.dropFirst().first ?? "")
        case "gh": return !ReadOnlyCommands.isReadOnly(segment)
        default: return false
        }
    }

    /// `gh` can act on GitHub in ways no flag list covers (`api`, aliases, extensions), so those never run
    /// unattended; the rest asks only for merges, deletions and anything that prints the credential.
    private static func ghIsSafe(_ arguments: [String]) -> Bool {
        let words = arguments.filter { !$0.hasPrefix("-") }
        let denied: Set<String> = [
            "api", "alias", "extension", "secret", "ssh-key", "gpg-key", "config", "codespace", "variable",
            "merge", "delete",
        ]
        if !denied.isDisjoint(with: words) { return false }
        if words.first == "auth" {
            let showsToken = hasFlag(flagSet(arguments), ["--show-token", "-t"])
            return words.dropFirst().first == "status" && !showsToken
        }
        return true
    }
}
