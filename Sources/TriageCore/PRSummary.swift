import Foundation

/// A few lines from a PR description saying what the PR is, for the item detail.
///
/// Takes the "Summary" (or Description / Overview / TL;DR) section when there is one, else the opening block
/// before the first heading or rule. Tables become one line per row ("jsdom · 30.0.1 → 30.1.0", as in
/// Renovate's). Images, HTML, comments and `<details>` blocks are dropped, links keep only their text, and
/// inline markdown (code, bold) stays for the view to render.
public enum PRSummary {
    static let maxLines = 8
    static let maxCharacters = 600

    public static func extract(_ body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let cleaned =
            body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"<details>[\s\S]*?</details>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let lines = cleaned.components(separatedBy: "\n")

        let block: ArraySlice<String>
        if let heading = lines.firstIndex(where: { summaryHeading.contains(headingText($0) ?? "") }) {
            block = section(lines, from: heading + 1)
        } else {
            let start = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? lines.endIndex
            block = section(lines, from: start)
        }

        var out: [String] = []
        var inTable = false
        for raw in block {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                defer { inTable = true }
                // The first row is the header, and a row of dashes separates it from the body.
                guard inTable, !isTableSeparator(line) else { continue }
                let cells = line.split(separator: "|").map { inline(String($0)) }.filter { !$0.isEmpty }
                if !cells.isEmpty { out.append("• " + cells.joined(separator: " · ")) }
                continue
            }
            inTable = false
            let text = inline(line)
            if text.isEmpty {
                if out.last?.isEmpty == false { out.append("") }  // keep one blank line between paragraphs
            } else {
                out.append(text)
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        guard !out.isEmpty else { return nil }
        return truncated(out)
    }

    static let summaryHeading: Set<String> = ["summary", "description", "overview", "tl;dr", "tldr"]

    /// The text of a markdown heading, lowercased and without a trailing colon, or nil if it isn't one.
    static func headingText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 1–6 #s then a space, so "#1234 follow-up" or "#hashtag" isn't a heading.
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
        let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    /// Lines from `start` up to the next heading or horizontal rule.
    static func section(_ lines: [String], from start: Int) -> ArraySlice<String> {
        let rest = lines[min(start, lines.endIndex)...]
        let end = rest.firstIndex { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return headingText(t) != nil || t == "---" || t == "***" || t == "___"
        }
        return rest[..<(end ?? rest.endIndex)]
    }

    static func isTableSeparator(_ line: String) -> Bool {
        line.allSatisfy { "|-: ".contains($0) }
    }

    /// Drops images and HTML tags, keeps only link text. Tags are only removed outside code spans, so
    /// `Result<Void, Error>` survives.
    static func inline(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .components(separatedBy: "`").enumerated()
            .map { index, part in
                guard index.isMultiple(of: 2) else { return part }
                return part.replacingOccurrences(
                    of: htmlTag, with: "", options: [.regularExpression, .caseInsensitive])
            }
            .joined(separator: "`")
            .trimmingCharacters(in: .whitespaces)
    }

    /// HTML tags seen in PR descriptions; anything else in angle brackets (`Array<String>`) is kept.
    static let htmlTag =
        #"</?(a|abbr|b|br|code|div|em|h[1-6]|hr|i|img|kbd|li|ol|p|picture|pre|source|span|strong|sub|sup|table"#
        + #"|tbody|td|th|thead|tr|u|ul|video)\b[^<>]*>"#

    static func truncated(_ lines: [String]) -> String {
        var text = lines.prefix(maxLines).joined(separator: "\n")
        var cut = lines.count > maxLines
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
            if let space = text.lastIndex(where: \.isWhitespace) { text = String(text[..<space]) }
            cut = true
        }
        return cut ? text.trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text
    }
}
