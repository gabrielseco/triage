import Foundation

/// Explain PR through Workbench (docs/plans/EXPLAIN.md): `workbench explain-pr --pr <n>` writes the explanation in
/// Markdown, Triage adds its front matter, keeps the note and opens it in Obsidian (or reveals it in Finder).
public enum ExplainPR {
    /// What Triage remembers of a finished explanation, per pull request.
    public struct Record: Codable, Sendable, Equatable {
        public var head: String
        public var note: String
        public var at: Date

        public init(head: String, note: String, at: Date) {
            self.head = head
            self.note = note
            self.at = at
        }
    }

    /// What an item shows under its Explain button.
    public enum Status: Equatable, Sendable {
        case none
        case running
        case done(note: String, at: Date)
        /// The note was written for an older head: the PR has moved since.
        case stale(note: String, at: Date)
    }

    public enum Failure: LocalizedError, Equatable {
        case workbenchNotFound
        case failed(String)
        case noFile(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .workbenchNotFound:
                "Workbench isn't installed, or its path isn't set in Settings."
            case .failed(let message): message
            case .noFile(let out): "Workbench reported no file: \(out)"
            case .unreadable(let path): "Couldn't read or write the note at \(path)."
            }
        }
    }

    /// What one run needs.
    public struct Job: Sendable {
        public var workbench: String
        public var checkout: String
        public var repo: RepoRef
        public var number: Int
        /// The head Triage last saw.
        public var head: String
        public var vault: String
        public var fallbackFolder: String

        public init(
            workbench: String, checkout: String, repo: RepoRef, number: Int, head: String, vault: String,
            fallbackFolder: String
        ) {
            self.workbench = workbench
            self.checkout = checkout
            self.repo = repo
            self.number = number
            self.head = head
            self.vault = vault
            self.fallbackFolder = fallbackFolder
        }
    }

    public struct Output: Sendable, Equatable {
        /// The note Triage wrote.
        public var note: String
        /// The head the explanation is for.
        public var head: String
    }

    // MARK: - Paths and contents

    public static func head7(_ sha: String) -> String { String(sha.prefix(7)) }

    /// `<owner>-<name>-<pr>-<head7>.md`, the note's file name; a GitLab group's slashes become dashes.
    public static func noteName(repo: RepoRef, number: Int, head: String) -> String {
        let slug = repo.fullName.replacingOccurrences(of: "/", with: "-")
        return "\(slug)-\(number)-\(head7(head)).md"
    }

    /// `<vault>/<path>-<pr>-<head7>.md`, where `<path>` is the repo's `owner/name` with dashes. With no vault the
    /// note goes in `fallbackFolder`, which the app reveals in Finder.
    public static func notePath(
        vault: String, fallbackFolder: String, repo: RepoRef, number: Int, head: String
    ) -> String {
        let folder = vault.trimmingCharacters(in: .whitespaces)
        let dir = folder.isEmpty ? fallbackFolder : (folder as NSString).expandingTildeInPath
        return (dir as NSString).appendingPathComponent(noteName(repo: repo, number: number, head: head))
    }

    /// The note: front matter with `pr`, `head` and `generated`, then Workbench's Markdown.
    public static func note(body: String, repo: RepoRef, number: Int, head: String, generated: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: generated)
        return """
            ---
            pr: \(repo.fullName)#\(number)
            head: \(head)
            generated: \(stamp)
            ---

            \(body.trimmingCharacters(in: .whitespacesAndNewlines))

            """
    }

    /// The link that opens a note in Obsidian: `obsidian://open?vault=<name>&file=<note>`, the form the app builds
    /// for its own "Copy Obsidian URL" (checked against Obsidian 1.15.0). The vault's name is its folder's name.
    public static func obsidianURL(vault: String, note: String) -> URL? {
        let folder = (vault.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !folder.isEmpty else { return nil }
        let name = URL(fileURLWithPath: folder).lastPathComponent
        let file = ((note as NSString).lastPathComponent as NSString).deletingPathExtension
        // encodeURIComponent keeps only these unescaped, so a space is %20, never "+".
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        guard let v = name.addingPercentEncoding(withAllowedCharacters: allowed),
            let f = file.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "obsidian://open?vault=\(v)&file=\(f)")
    }

    /// Where Triage keeps notes when no vault is set.
    public static func defaultFolder() -> String {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("dev.rogal.triage/explains", isDirectory: true).path
    }

    // MARK: - Status

    public static func status(record: Record?, currentHead: String, running: Bool) -> Status {
        if running { return .running }
        guard let record else { return .none }
        let moved = head7(record.head) != head7(currentHead)
        return moved ? .stale(note: record.note, at: record.at) : .done(note: record.note, at: record.at)
    }

    // MARK: - The Workbench command

    /// The command's arguments. No `--out`: the kept file is read back, so Triage controls where the note ends up.
    public static func arguments(number: Int) -> [String] { ["explain-pr", "--pr", String(number)] }

    /// Where a GUI app, which has no shell PATH, may find `workbench`.
    public static func workbenchCandidates(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/rogal/workbench/.build/release/workbench", "\(home)/.local/bin/workbench"]
            + ["/opt/homebrew/bin/workbench", "/usr/local/bin/workbench"]
    }

    public static func findWorkbench(setting: String, home: String = NSHomeDirectory()) -> String? {
        let set = (setting.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let candidates = set.isEmpty ? workbenchCandidates(home: home) : [set]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The contract: on success the last stdout line is the absolute path of the file, alone.
    public static func reportedFile(stdout: String) -> String? {
        let line = stdout.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(
            in: .whitespaces)
        guard let line, line.hasPrefix("/") else { return nil }
        return line
    }

    /// On failure stderr has one line, `workbench: <kind>: <message>`.
    public static func failureMessage(stderr: String, status: Int32) -> String {
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let text = line.hasPrefix("workbench: ") ? String(line.dropFirst("workbench: ".count)) : line
        return text.isEmpty ? "Workbench exited with status \(status)." : text
    }

    /// The head7 a kept file names: `pr-<n>-<head7>.md`.
    static func headInFileName(_ path: String) -> String? {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard base.hasPrefix("pr-"), let last = base.split(separator: "-").last, last.count == 7,
            last.allSatisfy(\.isHexDigit)
        else { return nil }
        return String(last)
    }

    // MARK: - Running

    /// Runs `workbench explain-pr` in `checkout` off the main actor (`Subprocess`), then writes the note. Workbench
    /// may explain a newer head than the one Triage last saw, so the head it names in the file wins when it differs.
    public static func run(_ job: Job, now: Date = Date()) async throws -> Output {
        let (workbench, checkout, repo, number) = (job.workbench, job.checkout, job.repo, job.number)
        let (head, vault, fallbackFolder) = (job.head, job.vault, job.fallbackFolder)
        let result: Subprocess.Output
        do {
            result = try await Subprocess.run(workbench, arguments(number: number), directory: checkout)
        } catch {
            throw Failure.failed("Couldn't start Workbench: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            throw Failure.failed(failureMessage(stderr: result.stderr, status: result.status))
        }
        guard let file = reportedFile(stdout: result.stdout) else { throw Failure.noFile(result.trimmedStdout) }
        guard let body = try? String(contentsOfFile: file, encoding: .utf8) else { throw Failure.unreadable(file) }
        var noteHead = head
        if let named = headInFileName(file), !head.hasPrefix(named) { noteHead = named }
        let path = notePath(vault: vault, fallbackFolder: fallbackFolder, repo: repo, number: number, head: noteHead)
        let text = note(body: body, repo: repo, number: number, head: noteHead, generated: now)
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.unreadable(path)
        }
        return Output(note: path, head: noteHead)
    }
}
