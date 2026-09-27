import Testing

@testable import TriageCore

@Test func renovateTablesBecomeOneLinePerPackage() {
    let body = """
        This PR contains the following updates:

        | Package | Change | [Age](https://docs.renovatebot.com/merge-confidence/) | [Confidence](https://x) |
        |---|---|---|---|
        | [jsdom](https://redirect.github.com/jsdom/jsdom) | [`30.0.1` → `30.1.0`](https://renovatebot.com/diffs/npm/jsdom/30.0.1/30.1.0) | ![age](https://developer.mend.io/a) | ![confidence](https://developer.mend.io/c) |

        ---

        ### Release Notes

        <details>
        <summary>jsdom/jsdom (jsdom)</summary>
        lots of notes
        </details>
        """
    #expect(PRSummary.extract(body) == "This PR contains the following updates:\n\n• jsdom · `30.0.1` → `30.1.0`")
}

@Test func takesTheSummarySectionOverTheOpening() {
    let body = """
        <!-- template hint: keep it short -->
        ## Summary

        Adds a script that proves a country's `contract_details` schema still submits end to end.

        ## Why

        ESP was recently moved from v1 to v7.
        """
    #expect(
        PRSummary.extract(body)
            == "Adds a script that proves a country's `contract_details` schema still submits end to end.")
}

@Test func headingNamesAreMatchedLoosely() {
    #expect(PRSummary.extract("# Intro\nskip\n### TL;DR:\nShort **version**.\n## More") == "Short **version**.")
    #expect(PRSummary.extract("## Description\nFixes the [login](https://x/y) bug.") == "Fixes the login bug.")
}

@Test func withoutASummaryHeadingTheOpeningBlockIsUsed() {
    let body = "\n\nFixes the flaky retry.\n\nAlso bumps the timeout.\n\n## Testing\n- ran it"
    #expect(PRSummary.extract(body) == "Fixes the flaky retry.\n\nAlso bumps the timeout.")
}

@Test func emptyOrUnusableDescriptionsGiveNothing() {
    #expect(PRSummary.extract(nil) == nil)
    #expect(PRSummary.extract("") == nil)
    #expect(PRSummary.extract("<!-- fill me in -->\n\n## Summary\n\n<!-- one sentence -->\n\n## Why") == nil)
    #expect(PRSummary.extract("![screenshot](https://x/y.png)") == nil)
}

@Test func longDescriptionsAreCutAtAWord() throws {
    let long = String(repeating: "word ", count: 300)
    let summary = try #require(PRSummary.extract(long))
    #expect(summary.count <= PRSummary.maxCharacters + 1)
    #expect(summary.hasSuffix("word…"))

    let many = (1...20).map { "- item \($0)" }.joined(separator: "\n")
    let lines = try #require(PRSummary.extract(many)).components(separatedBy: "\n")
    #expect(lines.count == PRSummary.maxLines)
    #expect(lines.last == "- item 8…")
}
