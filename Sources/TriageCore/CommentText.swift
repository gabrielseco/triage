import Foundation

/// Comment bodies as Triage shows them. Bots (Danger, Sonar, coverage reports) write HTML inside their Markdown,
/// and a Markdown renderer shows those tags as text, so the HTML becomes the Markdown it means: links, code, bold,
/// one line per table row or paragraph, with hidden `<!-- -->` metadata dropped. Prompts keep the raw body.
public enum CommentText {
    public static func readable(_ body: String) -> String {
        // Code is shown as written: `Array<Int>` or a fenced snippet of HTML isn't markup to convert.
        let parts = split(body.replacingOccurrences(of: "\r\n", with: "\n"))
        let s = parts.map { $0.isCode ? $0.text : convert($0.text) }.joined()
        return tidy(s)
    }

    /// Text and code (fenced blocks and inline spans), in order.
    static func split(_ s: String) -> [(text: String, isCode: Bool)] {
        guard let regex = try? NSRegularExpression(pattern: #"```[\s\S]*?```|`[^`\n]+`"#) else { return [(s, false)] }
        let ns = s as NSString
        var parts: [(String, Bool)] = []
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            parts.append((ns.substring(with: NSRange(location: last, length: m.range.location - last)), false))
            parts.append((ns.substring(with: m.range), true))
            last = m.range.location + m.range.length
        }
        parts.append((ns.substring(from: last), false))
        return parts
    }

    static func convert(_ text: String) -> String {
        var s = text
        // Hidden metadata (Danger's summary and id), and a table's header row, which is labels, not the finding.
        s = replace(#"<!--[\s\S]*?-->"#, in: s, with: "")
        s = replace(#"(?i)<thead\b[^>]*>[\s\S]*?</thead>"#, in: s, with: "")
        s = replace(#"(?i)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, in: s, with: "[$2]($1)")
        s = replace(#"(?i)</?(code|tt)\b[^>]*>"#, in: s, with: "`")
        s = replace(#"(?i)</?(b|strong)\b[^>]*>"#, in: s, with: "**")
        s = replace(#"(?i)</?(i|em)\b[^>]*>"#, in: s, with: "*")
        s = replace(#"(?i)<li\b[^>]*>"#, in: s, with: "• ")
        // Cells of a row stay on one line; rows, paragraphs and breaks end one.
        s = replace(#"(?i)</t[dh]>"#, in: s, with: " ")
        s = replace(#"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6]|table|ul|ol|details|summary)>"#, in: s, with: "\n")
        s = replace(#"(?i)</?(\#(tags))\b[^<>]*/?>"#, in: s, with: "")
        s = decodeEntities(s)
        return replace(#":([a-z0-9_+-]+):"#, in: s) { emoji[$0] }
    }

    /// HTML that comments use. Only these are removed, so `<T>` or `<Int>` in prose stays.
    static let tags = [
        "a", "p", "div", "span", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "br", "hr", "img", "picture",
        "source", "details", "summary", "sup", "sub", "b", "strong", "i", "em", "code", "tt", "pre", "kbd", "ul",
        "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "center", "font", "del", "s", "ins", "u",
        "small", "big", "caption", "colgroup", "col",
    ].joined(separator: "|")

    static func tidy(_ s: String) -> String {
        // Tags leave indentation and blank lines behind: one blank line at most, no leading spaces.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(
                of: #"\s{2,}"#, with: " ", options: .regularExpression)
        }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The shortcodes bots actually use; anything else stays as written.
    static let emoji: [String: String] = [
        "warning": "⚠️", "no_entry_sign": "🚫", "no_entry": "⛔", "x": "❌", "white_check_mark": "✅",
        "heavy_check_mark": "✔️", "rotating_light": "🚨", "bulb": "💡", "information_source": "ℹ️",
        "memo": "📝", "book": "📖", "lock": "🔒", "fire": "🔥", "tada": "🎉", "rocket": "🚀", "eyes": "👀",
        "bug": "🐛", "construction": "🚧", "exclamation": "❗", "question": "❓", "red_circle": "🔴",
        "large_orange_diamond": "🔶", "large_blue_circle": "🔵", "green_circle": "🟢", "yellow_circle": "🟡",
        "arrow_up": "⬆️", "arrow_down": "⬇️", "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉",
        "+1": "👍", "-1": "👎", "thumbsup": "👍", "thumbsdown": "👎",
    ]

    static func decodeEntities(_ s: String) -> String {
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        var out = named.reduce(s) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        out = replace(#"&#(x?)([0-9a-fA-F]+);"#, in: out) { match in
            let hex = match.hasPrefix("x")
            let digits = hex ? String(match.dropFirst()) : match
            return UInt32(digits, radix: hex ? 16 : 10).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        // Last, so "&amp;lt;" stays the text "&lt;".
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func replace(_ pattern: String, in s: String, with template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// Replaces each match of `pattern` with `transform(first capture group, or the whole match)`, keeping the
    /// match when it returns nil.
    static func replace(_ pattern: String, in s: String, transform: (String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (1..<m.numberOfRanges).map { m.range(at: $0) }.filter { $0.location != NSNotFound }
            let key = groups.map { ns.substring(with: $0) }.joined()
            out += transform(key) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
