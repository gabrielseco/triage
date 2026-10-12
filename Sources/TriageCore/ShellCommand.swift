import Foundation

/// Splits a shell command into simple commands without evaluating anything.
///
/// The permission policy can only reason about commands it fully understands, so every construct that
/// hides what will run (substitution, expansion, subshells, background jobs, arbitrary redirects, comments)
/// makes the whole command unparseable and the caller falls back to asking.
public enum ShellCommand {
    /// Redirections that only discard output or merge streams, and so can't write a file.
    private static let harmlessRedirects: Set<String> = [
        "2>&1", "1>&2", ">&2", ">/dev/null", "1>/dev/null", "2>/dev/null", "&>/dev/null",
    ]

    /// One array of unquoted words per simple command (`&&`, `||`, `;`, `|` and newlines separate them),
    /// or `nil` when the command uses syntax this policy doesn't model.
    public static func segments(_ command: String) -> [[String]]? {
        var scanner = Lexer(characters: Array(command))
        return scanner.run() ? scanner.segments : nil
    }

    private struct Lexer {
        let characters: [Character]
        var index = 0
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var isRedirect = false
        /// After `&&`, `||` or `|` a command must follow.
        var needsCommand = false

        init(characters: [Character]) { self.characters = characters }

        mutating func run() -> Bool {
            while index < characters.count {
                let character = characters[index]
                index += 1
                guard step(character) else { return false }
            }
            guard finishWord(), !(needsCommand && words.isEmpty) else { return false }
            if !words.isEmpty { segments.append(words) }
            return !segments.isEmpty
        }

        private mutating func step(_ character: Character) -> Bool {
            switch character {
            case "'": return singleQuoted()
            case "\"": return doubleQuoted()
            case "\\": return escaped()
            case "$", "`", "(", ")": return false
            case " ", "\t", "\n", ";": return separator(character)
            case "|": return pipe()
            case "&": return ampersand()
            default: return plain(character)
            }
        }

        private mutating func separator(_ character: Character) -> Bool {
            guard finishWord() else { return false }
            switch character {
            case "\n": return endSegment(allowEmpty: true)
            case ";": return endSegment(allowEmpty: false)
            default: return true
            }
        }

        private mutating func plain(_ character: Character) -> Bool {
            // A comment, or brace expansion, which can name paths the policy never sees.
            if (character == "#" && !inWord) || "{}".contains(character) { return false }
            // An unquoted glob expands to entries this policy can't see, symlinks among them.
            if "*?[".contains(character) { return false }
            word.append(character)
            inWord = true
            if character == "<" || character == ">" { isRedirect = true }
            return true
        }

        private mutating func singleQuoted() -> Bool {
            inWord = true
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "'" { return true }
                word.append(character)
            }
            return false
        }

        private mutating func doubleQuoted() -> Bool {
            inWord = true
            while index < characters.count {
                let character = characters[index]
                index += 1
                switch character {
                case "\"": return true
                case "$", "`": return false
                case "\\":
                    guard index < characters.count else { return false }
                    word.append(characters[index])
                    index += 1
                default: word.append(character)
                }
            }
            return false
        }

        private mutating func escaped() -> Bool {
            guard index < characters.count else { return false }
            let next = characters[index]
            index += 1
            if next != "\n" {
                word.append(next)
                inWord = true
            }
            return true
        }

        private mutating func pipe() -> Bool {
            guard finishWord() else { return false }
            if index < characters.count {
                if characters[index] == "&" { return false }
                if characters[index] == "|" { index += 1 }
            }
            needsCommand = true
            return endSegment(allowEmpty: false)
        }

        private mutating func ampersand() -> Bool {
            if index < characters.count, characters[index] == "&" {
                index += 1
                needsCommand = true
                return finishWord() && endSegment(allowEmpty: false)
            }
            let startsRedirect = !inWord && index < characters.count && characters[index] == ">"
            guard startsRedirect || word.hasSuffix(">") else { return false }
            word.append("&")
            inWord = true
            isRedirect = true
            return true
        }

        private mutating func finishWord() -> Bool {
            defer {
                word = ""
                inWord = false
                isRedirect = false
            }
            guard inWord else { return true }
            if isRedirect { return harmlessRedirects.contains(word) }
            words.append(word)
            needsCommand = false
            return true
        }

        private mutating func endSegment(allowEmpty: Bool) -> Bool {
            if words.isEmpty { return allowEmpty }
            segments.append(words)
            words = []
            return true
        }
    }
}
