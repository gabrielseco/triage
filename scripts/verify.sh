#!/usr/bin/env bash
# The verify_command Workbench runs in a thread's worktree: build this worktree's Triage into a throwaway bundle,
# launch it on mock data, and screenshot its window into $WORKBENCH_PROOF_DIR once per `proof: screenshot: <name>` line
# in the goal. The app reaches nothing real (docs/plans/MOCK.md): no GitHub, no GitLab, no Keychain, no settings of the
# installed app, so there is nothing to wait for and nothing private in the picture. The installed
# ~/Applications/Triage.app is never touched: the build has its own bundle id (below), the window is found by the PID
# of the process started here, and only that PID is killed.
#   WORKBENCH_PROOF_DIR  absolute, empty directory for the PNGs (required)
#   WORKBENCH_GOAL       path of the goal file (required)
#   VERIFY_FIXTURE      the mock scenario (default Mocks/default.json); a goal that needs another state names its file
#   VERIFY_SETTLE_SECONDS  wait after the window appears, for the first refresh (default 3)
#   VERIFY_WINDOW_SIZE  <width>x<height> in points the window is set to before any capture (default 1440x900). The
#                       window opens near the app's minimum, which cuts the sidebar. Needs Accessibility; without it
#                       the capture is at the launch size, with a note.
# A screenshot named <name> is taken after the steps in scripts/verify-steps/<name>.steps, if that file exists: one
# step per line, `press <label>` (scripts/ax.swift, on this build only) or `wait <seconds>`. A name with no steps file
# captures the window as it is. Steps run in the order the goal names the screenshots, each from the state the last left.
# The terminal running this needs Screen Recording permission, and Accessibility when a steps file is used.
set -euo pipefail

: "${WORKBENCH_PROOF_DIR:?WORKBENCH_PROOF_DIR is not set}"
: "${WORKBENCH_GOAL:?WORKBENCH_GOAL is not set}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FIXTURE="${VERIFY_FIXTURE:-$ROOT/Mocks/default.json}"
[[ -f "$FIXTURE" ]] || { echo "No such mock scenario: $FIXTURE" >&2; exit 1; }
FIXTURE="$(cd "$(dirname "$FIXTURE")" && pwd)/$(basename "$FIXTURE")"

WINDOW_SIZE="${VERIFY_WINDOW_SIZE:-1440x900}"
[[ "$WINDOW_SIZE" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || { echo "Bad VERIFY_WINDOW_SIZE: $WINDOW_SIZE (want <width>x<height>)" >&2; exit 1; }

names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && names+=("$name")
done < <(sed -nE 's/^[[:space:]-]*proof:[[:space:]]*screenshot:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$WORKBENCH_GOAL")

# `workbench doctor` runs this with a stub goal that names nothing; exiting 0 there proves nothing, so it gets one capture
# and exercises the build, the launch and the permissions.
if [[ ${#names[@]} -eq 0 && "${WORKBENCH_THREAD:-}" == "doctor" ]]; then
  names=(doctor)
fi

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
# throwaway build gets its own id. Mock mode keeps its settings in its own domain too (MockMode.defaultsSuite).
VERIFY_ID="dev.rogal.triage.verify"
MOCK_DOMAIN="dev.rogal.triage.mock-state"
TMP="$(mktemp -d)"
LOG="$TMP/triage.log"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  for domain in "$VERIFY_ID" "$MOCK_DOMAIN"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$domain.plist"  # `defaults delete` leaves an empty file
  done
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

TRIAGE_FIXTURE="$FIXTURE" "$APP/Contents/MacOS/Triage" >"$LOG" 2>&1 &
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

# Before the settle wait, so the first refresh lays out at the final size. A failure (no Accessibility) is a note: the
# capture is then at the launch size, as before.
if ! TRIAGE_PID="$PID" swift "$ROOT/scripts/ax.swift" resize "${WINDOW_SIZE%x*}" "${WINDOW_SIZE#*x}" >&2; then
  echo "Could not resize the window (is Accessibility granted to this terminal?); capturing at the launch size." >&2
fi
if info="$(swift "$ROOT/scripts/window-info.swift" "$PID" 2>/dev/null)"; then
  read -r _ _ _ width height <<<"$info"
  echo "window: ${width}x${height}"
fi

sleep "${VERIFY_SETTLE_SECONDS:-3}"  # the first refresh reads the scenario: a moment for the list to lay out
# A steps file is reviewed in a PR and only has these two verbs. A button that acts on a forge, opens another app or
# spends money is refused even if a file names it: the mock has nothing to lose, but a steps file is also read against the
# real app.
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
        # The early check above is for a clear message; ax.swift checks the label the prefix resolves to.
        TRIAGE_PID="$PID" TRIAGE_REFUSE="$refused" swift "$ROOT/scripts/ax.swift" press "$arg" >&2 || return 1
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
