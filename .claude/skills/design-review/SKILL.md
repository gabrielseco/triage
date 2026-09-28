---
name: design-review
description: Review how a PR's UI looks from a product designer's point of view — hierarchy, alignment and spacing, typography, color and contrast in light and dark mode, truncation at the minimum window size, empty/loading/error states, and fit with native macOS conventions — checked against docs/DESIGN.md and Apple's HIG. Builds the PR into a throwaway bundle (the /verify mechanics), captures a matrix of states, pairs the screenshots with a static pass over the SwiftUI diff, and posts graded findings on the PR. Use after /verify for any PR that changes something visible in the app, or when the user asks for a "design review", "does this look good", "check the design" or "polish pass".
allowed-tools: Bash(scripts/bundle.sh:*), Bash(scripts/snap.sh:*), Bash(TRIAGE_APP=*), Bash(open:*), Bash(pkill:*), Bash(pgrep:*), Bash(swift scripts/ax.swift:*), Bash(osascript:*), Bash(sips:*), Bash(gh:*), Bash(git:*), Bash(grep:*), Bash(rm:*), Read, Grep
---

# Design review

`/verify` asks "does it do what the PR says?". This asks "does it look right?": would a designer who knows
the Mac sign off on it. The standard is `docs/DESIGN.md` (this app's rules) and then Apple's Human
Interface Guidelines for macOS. Findings cite one of them, not taste.

Scale to the diff: a copy or color tweak gets one or two captures; a new view or a layout change gets the
full matrix.

## Step 1: Scope

Read `docs/DESIGN.md`, then the PR (`gh pr view <n> --json title,body,files`, `gh pr diff <n>`). Before the
PR exists (right after `/verify` while building), use the worktree's `git diff origin/main...` instead. List:

- **Surfaces touched:** sidebar, inbox rows / PR header, item detail, toolbar, Settings, menu bar, notifications.
- **States each one can be in:** the normal case plus whichever of these the diff can affect: empty, loading,
  error, long text (long PR title, long repo name, long author), many items, selected, hover, disabled.

If the diff has nothing visible, say so and stop.

## Step 2: Static pass over the diff

These are certain, so do them before looking at pixels. In the added lines of `Sources/Triage/**`:

- `.font(.system(size:` or `.font(.custom(` → should be a text style (DESIGN.md › Typography).
- `Color(red:`, `Color(#`, `NSColor(` literals → should be semantic (DESIGN.md › Color).
- `.padding(` / `spacing:` values outside 2, 4, 5, 6, 8, 10, 16, 20.
- A `Text` in a row or header with no `lineLimit`.
- A `Button`/`Image` that shows only an icon, with no `.help(`.
- A second `.borderedProminent` in the same view state.
- `.yellow` on text, or color as the only thing that distinguishes two states.
- Custom-drawn controls where a system one exists (e.g. a `RoundedRectangle` + `onTapGesture` acting as a button).

Note each hit with `file:line`. It's a finding only if the screenshot or the context confirms it matters.

## Step 3: Capture the matrix

Use `/verify`'s Steps 2, 3 and 5 exactly (throwaway bundle at `<scratchpad>/verify/Triage.app`, swap it in,
**always restore**, even on failure). Its rules on side effects apply: this is the user's real account,
so never press Close, Merge, Explain or anything that posts. Save captures under `<scratchpad>/design/`, named
`<surface>-<state>-<light|dark>-<size>.png`.

For each surface and state from Step 1:

- **Light and dark.** Relaunch the PR build with the appearance forced for that app only:
  ```bash
  V=<scratchpad>/verify/Triage.app
  [[ "$V" == */verify/Triage.app ]] || exit 1    # never let the pattern match the installed app
  pkill -f "$V/Contents/MacOS/Triage"; sleep 1
  open "$V" --args -AppleInterfaceStyle Dark     # plain `open "$V"` for light (if the system is light)
  ```
  Check the first dark capture really is dark. If the system itself is in dark mode, the light pass needs the user
  to switch System Settings › Appearance, so ask for that. Don't change it yourself.
- **Two sizes.** Minimum (1000×600) and roomy (1600×1000):
  ```bash
  V=<scratchpad>/verify/Triage.app
  [[ "$V" == */verify/Triage.app ]] || exit 1
  PID=$(pgrep -nf "$V/Contents/MacOS/Triage") || exit 1
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set size of window 1 to {1000, 600}"
  ```
- **States:** reach them with `swift scripts/ax.swift press "<label>"` (select a row, open a filter, hover isn't
  reachable, so read it from code). For states the real data doesn't have (empty inbox, error, a very long title),
  pick a sidebar filter that is empty, or a repo with long names, and if it can't be reached, say
  "not captured" and review it from the code. Never fake data in the user's settings.
- **Before:** for a changed surface, capture the same shots from `origin/main` (a throwaway worktree through the same
  steps) so the report can put them side by side.

Read every capture (use `sips -Z 1600` on a copy first). Look at it. Don't assume it rendered.

## Step 4: Review like a designer

Go through each capture with these questions, in this order, most important first:

1. **Hierarchy.** In one second, is it clear what needs attention and what to do? Is the primary action the
   most prominent control, and is there only one?
2. **Alignment and rhythm.** Do leading edges line up across rows and sections? Is spacing consistent between
   siblings, and larger between groups than within them? Anything off by a few points?
3. **Typography.** Styles per the DESIGN.md table, no more than three sizes in a component, weight and
   `.secondary` doing the hierarchy work.
4. **Color and contrast.** Meaning-only color, same meaning → same color, readable in both appearances
   (watch tinted pills and `.secondary` on `.quaternary`), never color alone.
5. **Fit at the minimum size.** Truncates with an ellipsis rather than clipping or overlapping; toolbar and
   button rows don't collapse into a mess; nothing important is pushed off screen.
6. **States.** Empty says what to do next; loading shows progress in place; errors are inline and specific.
7. **Native feel.** Would it look at home next to Mail or Xcode? Standard controls, SF Symbols with consistent
   fill/outline, sentence-case labels, tooltips on icon-only controls, keyboard shortcuts where siblings have them.
8. **Consistency with the rest of Triage.** A new badge, card or row matches the existing ones (compare with an
   unchanged neighbouring view).

Grade each finding:

- **Blocking:** broken or clipped layout, unreadable text (either appearance), wrong meaning of a color, a
  primary action that's hard to find, something that doesn't fit at 1000×600.
- **Polish:** misalignment, inconsistent spacing or style, weak hierarchy, a missing tooltip or empty state.
- **Nit:** subjective. Say it's subjective, at most three.

Each finding: what's wrong, the screenshot, the rule it breaks (DESIGN.md section or HIG), and the SwiftUI fix at
`file:line`. Say what works well too, in a line: it tells the author what to keep.

## Step 5: Report and post

- In the chat: verdict (**looks good** / **polish needed** / **blocking issues**), findings by grade, and the list
  of screenshot paths (light/dark, before/after) for the user to drag into the PR's Screenshots table.
- On the PR, once it exists (before that, the chat report is enough): one review, posted the way `/pr-review`
  does (`gh api repos/<owner>/<repo>/pulls/<n>/reviews --input <json>`, `"event": "COMMENT"`, head `commit_id`,
  `comments[]` of `{path, line, side: "RIGHT", body}`). The body carries the verdict. Label each comment
  `issue (blocking, design):`, `suggestion (design):` or `nitpick (design):` and end it with `[by Claude]`.
  Findings that don't point at a line go in the body. With nothing to report, post a short
  `gh pr review <n> --comment --body "Design review: no findings [by Claude]"`.
- Blocking findings get fixed on the branch before the PR is marked ready, then run this again. Polish is fixed
  unless the user says otherwise.
- If a finding shows DESIGN.md is wrong or silent (a new pattern the PR introduces on purpose), propose the
  DESIGN.md edit in the same PR instead of flagging the code.
