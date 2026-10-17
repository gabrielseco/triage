#!/usr/bin/env bash
# The verify_command Workbench runs in a thread's worktree: build this worktree's Triage into a throwaway bundle,
# launch it, and screenshot its window into $WORKBENCH_PROOF_DIR once per `proof: screenshot: <name>` line in the goal.
# The installed ~/Applications/Triage.app is never touched: the build has its own bundle id (below), the window is found
# by the PID of the process started here, and only that PID is killed.
#   WORKBENCH_PROOF_DIR  absolute, empty directory for the PNGs (required)
#   WORKBENCH_GOAL       path of the goal file (required)
#   VERIFY_SETTLE_SECONDS  wait after the window appears, for the first refresh (default 15)
# A screenshot named <name> is taken after the steps in scripts/verify-steps/<name>.steps, if that file exists: one
# step per line, `press <label>` (scripts/ax.swift, on this build only) or `wait <seconds>`. A name with no steps file
# captures the window as it is. Steps run in the order the goal names the screenshots, each from the state the last left.
# The terminal running this needs Screen Recording permission, and Accessibility when a steps file is used.
set -euo pipefail

: "${WORKBENCH_PROOF_DIR:?WORKBENCH_PROOF_DIR is not set}"
: "${WORKBENCH_GOAL:?WORKBENCH_GOAL is not set}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && names+=("$name")
done < <(sed -nE 's/^[[:space:]-]*proof:[[:space:]]*screenshot:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$WORKBENCH_GOAL")

if [[ ${#names[@]} -eq 0 ]]; then
  echo "No 'proof: screenshot:' lines in $WORKBENCH_GOAL, nothing to capture."
  exit 0
fi
for name in "${names[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != .* ]] || { echo "Bad screenshot name: $name" >&2; exit 1; }
done

# Without Screen Recording, screencapture saves a wallpaper-only image instead of failing.
if ! swift - <<'SWIFT'
import CoreGraphics
exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
SWIFT
then
  echo "Screen Recording permission is missing: grant it to this terminal/app in System Settings > Privacy & Security." >&2
  exit 1
fi

for name in "${names[@]}"; do
  [[ -f "$ROOT/scripts/verify-steps/$name.steps" ]] || continue
  if ! swift - <<'SWIFT'
import ApplicationServices
exit(AXIsProcessTrusted() ? 0 : 1)
SWIFT
  then
    echo "Accessibility permission is missing (needed to press buttons for $name): grant it in System Settings > Privacy & Security." >&2
    exit 1
  fi
  break
done

# A second process with the installed app's bundle id (dev.rogal.triage) starts but opens no window, so the
# throwaway build gets its own id, and with it its own settings domain, deleted again on exit.
VERIFY_ID="dev.rogal.triage.verify"
TMP="$(mktemp -d)"
LOG="$TMP/triage.log"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  defaults delete "$VERIFY_ID" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$VERIFY_ID.plist"  # `defaults delete` leaves an empty file
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP="$TMP/Triage.app"
TRIAGE_APP="$APP" "$ROOT/scripts/bundle.sh" >&2
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $VERIFY_ID" "$APP/Contents/Info.plist"
# Changing the plist breaks the signature bundle.sh made. Sign with the same stable identity, as bundle.sh does: an ad hoc
# signature differs on every run, so macOS asks again for each Keychain item the app reads (GitLab, Linear, Anthropic).
SIGN_ID="Triage Local Signing"
security find-identity -p codesigning | grep -qF "\"$SIGN_ID\"" || SIGN_ID="-"
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1

# Read-only copy of the installed app's repo list and filters, so the screenshot has something to show. Only
# these keys: the alert state and the secret references stay out, so the pilot cannot notify or ask 1Password.
defaults delete "$VERIFY_ID" 2>/dev/null || true
swift - "$VERIFY_ID" <<'SWIFT' >&2
import Foundation
let target = CommandLine.arguments[1]
let keep = ["repos", "onlyMine", "gitlabHost"]
let source = UserDefaults.standard.persistentDomain(forName: "dev.rogal.triage") ?? [:]
UserDefaults.standard.setPersistentDomain(source.filter { keep.contains($0.key) }, forName: target)
SWIFT

"$APP/Contents/MacOS/Triage" >"$LOG" 2>&1 &
PID=$!

id=""
SECONDS=0  # wall clock: each lookup starts the Swift interpreter, so counting iterations would overrun 60 s
while ((SECONDS < 60)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  if info="$(swift "$ROOT/scripts/window-info.swift" "$PID" 2>/dev/null)"; then
    read -r id _ <<<"$info"
    break
  fi
  sleep 0.5
done

if [[ -z "$id" ]]; then
  echo "Triage (pid $PID) showed no window within 60 s. End of its output:" >&2
  tail -n 40 "$LOG" >&2
  exit 1
fi

sleep "${VERIFY_SETTLE_SECONDS:-15}"  # the first refresh is a network fetch: the list is empty until it ends
# A steps file is reviewed in a PR and only has these two verbs. A button that acts on a forge, opens another app or
# spends money is refused even if a file names it: this build holds the user's real GitHub login.
refused='^(Approve|Merge|Squash|Rebase|Close|Open|Fix in iTerm|Explain)'
run_steps() {
  local file="$1" verb arg
  while IFS=' ' read -r verb arg || [[ -n "$verb" ]]; do
    case "$verb" in
      '' | '#'*) ;;
      wait)
        [[ "$arg" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "$file: bad wait: $arg" >&2; return 1; }
        sleep "$arg"
        ;;
      press)
        if [[ -z "$arg" || "$arg" =~ $refused ]]; then echo "$file: refused step: press $arg" >&2; return 1; fi
        TRIAGE_PID="$PID" swift "$ROOT/scripts/ax.swift" press "$arg" >&2 || return 1
        ;;
      *) echo "$file: unknown step: $verb" >&2; return 1 ;;
    esac
  done <"$file"
}

for name in "${names[@]}"; do
  steps="$ROOT/scripts/verify-steps/$name.steps"
  if [[ -f "$steps" ]]; then
    run_steps "$steps" || { echo "The steps for $name failed" >&2; exit 1; }
    sleep 1.5  # SwiftUI animates the change
  fi
  screencapture -x -o -l "$id" "$WORKBENCH_PROOF_DIR/$name.png"
  echo "$WORKBENCH_PROOF_DIR/$name.png"
done
