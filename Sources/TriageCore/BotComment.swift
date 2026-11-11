import Foundation

/// What a bot comment is, so only findings reach the inbox. Status lines ("review complete") and reports
/// (a run summary) are counted as muted instead. Unknown comments are findings: showing too much beats
/// hiding a real problem.
public enum BotCommentKind: Sendable, Equatable {
    case finding, status, report

    /// `resolvable` is false for a GitLab note that isn't a thread: bots post run summaries that way.
    static func of(_ body: String, resolvable: Bool = true) -> BotCommentKind {
        // Bots tag their own comments with a hidden marker, e.g. `<!-- devbox-ocr:status -->`.
        if let m = body.firstMatch(of: /<!--\s*[\w.\-]+:(status|finding|summary|report)\s*-->/) {
            switch m.1 {
            case "finding": return .finding
            case "status": return .status
            default: return .report
            }
        }
        // Without a marker only a short, non-thread note that just announces progress is a status.
        // "Scan completed: 3 vulnerabilities" is a finding, so alarm words keep it out.
        let alarming = Classifier.alarmWords.contains { body.lowercased().contains($0) }
        let progress = #"\b(complete|completed|finished|in progress|started|passed|queued)\b"#
        let announces = body.range(of: progress, options: [.regularExpression, .caseInsensitive]) != nil
        if !resolvable, body.count < 200, !alarming, announces {
            return .status
        }
        return .finding
    }

    /// A bot's own `**[category · severity]**` tag (Open Code Review), e.g. `[test · medium]`.
    static func taggedSeverity(_ body: String) -> Severity? {
        guard let m = body.firstMatch(of: /\[[^\]\n·]+·\s*(critical|high|medium|low)\s*\]/.ignoresCase()) else {
            return nil
        }
        switch m.1.lowercased() {
        case "critical", "high": return .high
        case "medium": return .medium
        default: return .low
        }
    }
}
