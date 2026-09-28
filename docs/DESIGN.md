# Design

What Triage should look like, written down so a change can be checked against it (`/design-review`).
It describes the UI as it is today; when a PR deliberately changes a rule, update this file in the same PR.

## Principles

1. **A native Mac app, not a web page.** Use what Mail and Xcode use: `NavigationSplitView`, `List` with
   sections, toolbar items, `GroupBox`, `ContentUnavailableView`, standard button styles and menus. No custom
   chrome, no card-heavy layouts, no hand-made controls when a system one exists.
2. **The answer first.** Triage exists to say what needs you. In a row, the thing to act on (kind + headline)
   comes before the metadata. In the detail, the headline and the primary action are the first things the eye lands on.
3. **Quiet by default, loud only for severity.** Almost everything is `.primary` or `.secondary`. Color carries
   meaning (severity, CI state, "you"), never decoration.
4. **Dense, not cramped.** It's a triage tool read many times a day: compact rows, but every text has room to
   breathe and nothing collides at the minimum window size.

## Layout

- Three columns: sidebar (min 200, ideal 230), inbox (min 340, ideal 420), detail (the rest). The window's
  minimum is 1000×600, and everything must still fit, truncating without clipping, at that size.
- Detail view: `padding(20)`, sections stacked with `spacing: 16`, inner groups with `spacing: 6`.
- Rows: `spacing: 2` between stacked lines, `8` between icon and text, `padding(.vertical, 2)`.
- Spacing values come from this set: **2, 4, 5, 6, 8, 10, 16, 20**. A new value needs a reason.
- Leading edges line up: icons in a column share a fixed `frame(width:)` (e.g. 18 in `ItemRow`) so the text aligns.

## Typography

Text styles only, never `.font(.system(size:))`, so it scales with the system.

| Role | Style |
| --- | --- |
| Detail headline | `.title2.weight(.semibold)` |
| Section title ("Evidence") | `.headline` |
| PR title in a row, card title, item kind in detail | `.subheadline.weight(.semibold)` |
| Body, headline in a row | default (`.body`) |
| Summaries, evidence detail, toolbar summary | `.callout` + `.secondary` |
| Metadata, kind label in a row, errors | `.caption` |
| Pills, counts in headers | `.caption2` |
| Repo `name #number` | `.caption.monospaced()` |
| Counts | `.monospacedDigit()` |

At most three sizes visible in one component. Hierarchy comes from weight and `.secondary` before size.

## Color

- Semantic colors only: `.primary`, `.secondary`, `.quaternary`, `Color.accentColor`, and the system
  `.red/.orange/.yellow/.green`. No `Color(red:green:blue:)` or hex. Everything must read in light and dark mode.
- Severity: high `.red`, medium `.orange`, low `.yellow`, info `.green` (`Severity.color`). CI: failing red,
  running orange, passed green. The same meaning always gets the same color.
- Color is never the only signal: severity and CI always pair color with an SF Symbol and/or a label.
- Tinted backgrounds are the color at `opacity(0.15)` (badges) or `0.2` (the "you" pill). Neutral surfaces use
  `.quaternary` (cards at `opacity(0.5)`).
- `.yellow` text on a light background is hard to read; use yellow only for symbols, not text.

## Components

- **Pills / badges:** text in a `Capsule()` background, `.padding(.horizontal, 4–6)`, `.padding(.vertical, 2)`
  when they sit next to other text. Short, lowercase for states ("draft", "you").
- **Cards** (`EvidenceCard`): `padding(10)`, `RoundedRectangle(cornerRadius: 8)`, full width.
- **Buttons:** one `.borderedProminent` primary action per state (Merge, or Explain & propose fix); the rest
  default. Secondary actions sit on the leading side, and state changes (Snooze, Dismiss, Open) sit on the
  trailing side after a `Spacer()`. Menus that sit in a button row get `.fixedSize()`.
- **Icons:** SF Symbols only, via `Label` where there's text. Filled variants for status (`xmark.circle.fill`),
  outline for actions and navigation.
- **Empty states:** `ContentUnavailableView` with a symbol, a short title and a sentence that says what to do next.
- **Tooltips:** every button or icon whose meaning isn't in its visible text gets `.help(...)`, and so does any text
  that truncates and matters.

## Text

- Every `Text` in a list row has a `lineLimit` (titles 1, headlines 2, warnings 3).
- Labels are sentence case ("Explain & propose fix", "Stop watching"). Menu items that ask for confirmation end in "…".
- Copy is plain and short. Say what happened or what to do, not how the code works.

## Motion and feedback

- Anything that takes time shows a small `ProgressView()` in place of the control that triggered it.
- Errors show inline, next to what failed, in `.red` `.caption`. They aren't alerts.
