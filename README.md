# Triage

Native macOS inbox for open PRs across the repos you watch. Collapses CI runs, bot chatter and review
threads into a short list of things that actually need you, and turns each one into a prompt Claude
can explain or fix.

```bash
scripts/bundle.sh    # build ~/Applications/Triage.app (the `triage` zsh function does this + launches)
swift test           # classifier, prompt builder, digest
```

`swift run Triage` works for quick UI iteration, but notifications and "open at login" need the bundle.

**Digests:** at 12:00 and 18:00 on weekdays (Settings to change), the app notifies what's new since the
previous digest ("3 new since 12:00 · 13 open · 4 cleared"). Clicking it opens the "New at …" filter.
A missed slot (asleep / app closed) goes out on the next refresh after it.

Auth: `GITHUB_TOKEN` or the `gh` CLI token; `ANTHROPIC_API_KEY` or a key saved in Settings (Keychain).

## How it works

Full walkthrough (with Swift ↔ React/TS/Elixir mappings): [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md)

`GitHub GraphQL snapshot → Classifier → attention items → you decide → Claude explains / you fix`

- **Sources/TriageCore/Classifier.swift** — deterministic rules. One item per (PR, kind): all failing
  checks on a head sha are one item, all findings from one bot are one item. Noise bots (coverage,
  deploy previews, dependabot…) are counted and muted. Item ids include the head sha / latest comment,
  so dismissing is sticky until something new happens.
- **PromptBuilder** — assembles evidence + failing job log tails + the diff into one prompt
  (same pattern as expenses-backend's `get_*_prompt` tools). Two modes: "explain" (sent to Claude from
  the app) and "Claude Code" (paste into a local checkout to fix).
- **AnthropicClient** — raw Messages API call (`claude-opus-5`, server-side refusal fallback).

## Next: Phoenix backend (multi-tenant)

Move `GitHubClient` + `Classifier` + prompt assembly server-side:
GitHub App (webhooks + per-installation tokens) → Oban ingestion → `pull_requests` / `signals` /
`attention_items` / `agent_runs` tables → REST + Phoenix Channels for the app, MCP for Claude.
The "Fix it" agent then runs server-side as a tool-use loop whose tools are GitHub API calls
(read file, search, get logs, commit to branch); CI is the test runner, so no sandboxes needed.
