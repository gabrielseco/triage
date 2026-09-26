## Summary

<!--
One or two plain-language sentences: what problem this solves and the outcome for
someone using Triage. No internal type/function names. Be VERY concise.
-->

## Why

<!--
The user problem, and why this approach over the alternatives.
The diff shows *what* changed, not *why*. Short, simple sentences.
-->

## What changed

<details>
<summary>Toggle details</summary>

<!--
Implementation detail for the reviewer: design decisions, trade-offs, known
limitations, which files need the closest look. Call out explicitly if this:
- changes an attention item's id, kind or severity (dismissals, digests, badge counts)
- renames a UserDefaults key or changes a persisted type (silently resets settings)
- touches secrets, the handoff script, or AppleScript
- adds a GitHub query field or an extra request per refresh (rate limit)
-->

</details>

## Screenshots

<details>
<summary>Toggle screenshots</summary>

<!--
Put your screenshots below if this changes the UI (sidebar, item detail, menu bar,
Settings, a notification). If not, replace this whole <details> block with "N/A".
-->

| Before | After  |
| ------ | ------ |
| <here> | <here> |

</details>

## Related Resources

<!--
Links related to this PR: issues, other PRs, Slack threads, etc. "N/A" if none.
-->

## Testing

<!-- How to test this PR. "N/A" if not applicable. -->

- [ ] `scripts/check.sh` passes (lint, Swift 6 build, tests)
- [ ] Tried in the bundled app (`scripts/bundle.sh`) — needed for notifications, login item and Fix in iTerm
