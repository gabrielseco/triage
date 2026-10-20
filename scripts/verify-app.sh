#!/usr/bin/env bash
# The throwaway Triage build that /verify and Workbench drive, and nothing else: it never touches the installed
# ~/Applications/Triage.app. The /verify skill, run by Workbench's verifier, drives it, so the parts that keep a verification safe are
# written once and the model has nothing else to call.
#   scripts/verify-app.sh start [scenario.json]   build this checkout, launch it on mock data, print its pid and window
#                                                 id, and leave it running (default scenario: Mocks/default.json)
#   scripts/verify-app.sh list <pid>              what is on screen: role <tab> label
#   scripts/verify-app.sh press <pid> "<label>"   press that button, or select that row
#   scripts/verify-app.sh shot <pid> <name>       screenshot the window into $WORKBENCH_PROOF_DIR/<name>.png
#   scripts/verify-app.sh stop <pid>              end that build, and remove it and its settings
#   scripts/verify-app.sh serve [scenario.json]   `start`, then stay in the foreground until told to end (SIGTERM or Ctrl-C),
#                                                 and remove the build then. For Workbench's `[run]`, which starts and ends it:
#                                                 it prints "Triage is up" when the window is on screen. `list`, `press` and
#                                                 `shot` take `run` in place of the pid, meaning that build; `stop` does not.
# Every command after `start` takes the pid `start` printed (or `run` under `serve`) and refuses any other: a pid it did not start, the installed
# app, or a process that has since been replaced, so the window, the button and the process are always this build's.
# Safety, each part written down because a model may be running this:
#   - the build has a bundle id of its own, new for each start (dev.rogal.triage.verify-<number>), and the app is in mock mode (docs/plans/MOCK.md): it
#     reaches no GitHub, GitLab or Keychain, reads none of the installed app's settings, and shows no private titles
#   - the window is found by pid, never by name, and only that pid is ever killed
#   - `press` refuses the buttons that act on a forge, open another app or spend money, by label, here and again in
#     scripts/ax.swift on the label it resolves to; a scenario file cannot widen the list
# Environment for `start`:
#   VERIFY_WINDOW_SIZE      <width>x<height> in points the window is set to before any capture (default 1440x900). Needs
#                           Accessibility; without it the window stays at its launch size, with a note.
#   VERIFY_SETTLE_SECONDS   wait after the window appears, for the first refresh (default 3)
# The terminal running this needs Screen Recording (start, shot) and Accessibility (press, list, resize).
# Exit codes: 0 done, 1 refused or failed (the reason on stderr), 2 usage.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# One id per start: a process that shares a bundle id with an earlier one that was killed can start and open no window, and
# nothing else says why. The id of a running build is kept in its directory.
ID_PREFIX="dev.rogal.triage.verify"
MOCK_DOMAIN="dev.rogal.triage.mock-state"  # MockMode.defaultsSuite
# The buttons a verification never presses, by the start of their label.
REFUSED='^(Approve|Merge|Squash|Rebase|Close|Open|Fix in iTerm|Explain)'
STATE_ROOT="${TMPDIR:-/tmp}"
STATE_ROOT="${STATE_ROOT%/}/triage-verify"
PIDS="$STATE_ROOT/pids"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

fail() {
  echo "verify-app: $*" >&2
  exit 1
}

# The pid of the build `serve` is holding for Workbench: `run` means that build. Anything else is returned as it came.
resolve_pid() {
  local arg="$1" file
  [[ "$arg" == run ]] || { printf '%s' "$arg"; return; }
  [[ "${WORKBENCH_RUN_PID:-}" =~ ^[1-9][0-9]*$ ]] || fail "'run' needs WORKBENCH_RUN_PID: there is no build that Workbench started"
  file="$PIDS/serve-$WORKBENCH_RUN_PID"
  [[ -f "$file" ]] || fail "no build is being served for pid $WORKBENCH_RUN_PID"
  printf '%s' "$(<"$file")"
}

# The directory of the build with this pid, only when that process is still the one we started from it.
build_dir() {
  local pid="$1" dir
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "not a pid: $pid"
  [[ -f "$PIDS/$pid" ]] || fail "pid $pid is not a build started by verify-app.sh start"
  dir="$(<"$PIDS/$pid")"
  [[ "$(ps -o command= -p "$pid" 2>/dev/null)" == "$dir/Triage.app/Contents/MacOS/Triage"* ]] ||
    fail "pid $pid is not running the build in $dir (it ended, or the pid was reused)"
  printf '%s' "$dir"
}

# The settings of the build with this bundle id (empty: only the mock domain, which every build shares).
forget_settings() {
  local id="${1:-}" domain
  for domain in ${id:+"$id"} "$MOCK_DOMAIN"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$domain.plist"  # `defaults delete` leaves an empty file
  done
  [[ -z "$id" ]] || rm -rf "$HOME/Library/Saved Application State/$id.savedState" "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id"
}

# Ends the build with this pid and removes what it left. Quiet when there is nothing to do.
remove_build() {
  local pid="$1" dir="" id=""
  [[ -f "$PIDS/$pid" ]] && dir="$(<"$PIDS/$pid")"
  [[ -n "$dir" && -f "$dir/bundle-id" ]] && id="$(<"$dir/bundle-id")"
  if [[ -n "$dir" && "$(ps -o command= -p "$pid" 2>/dev/null)" == "$dir/Triage.app/Contents/MacOS/Triage"* ]]; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDS/$pid"
  [[ -n "$dir" && "$dir" == "$STATE_ROOT"/build.* ]] && rm -rf "$dir"
  [[ "$id" == "$ID_PREFIX"-* ]] && forget_settings "$id"
  return 0
}

# Builds a crashed or killed run left: a pid file whose process is gone.
remove_stale() {
  local file pid
  [[ -d "$PIDS" ]] || return 0
  for file in "$PIDS"/*; do
    [[ -f "$file" ]] || continue
    [[ "$(basename "$file")" == serve-* ]] && continue  # a live `serve` owns its file and removes it on exit
    pid="$(basename "$file")"
    kill -0 "$pid" 2>/dev/null || remove_build "$pid"
  done
}

start() {
  local scenario="${1:-$ROOT/Mocks/default.json}" size="${VERIFY_WINDOW_SIZE:-1440x900}"
  [[ -f "$scenario" ]] || fail "no such mock scenario: $scenario"
  scenario="$(cd "$(dirname "$scenario")" && pwd)/$(basename "$scenario")"
  [[ "$size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || fail "bad VERIFY_WINDOW_SIZE: $size (want <width>x<height>)"

  # Without Screen Recording, screencapture saves a wallpaper-only image instead of failing.
  if ! swift - <<'SWIFT'
import CoreGraphics
exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
SWIFT
  then
    fail "Screen Recording permission is missing: grant it to this terminal/app in System Settings > Privacy & Security."
  fi

  mkdir -p "$PIDS"
  remove_stale
  # Global, not local: the EXIT trap runs after this function has returned.
  tmp="$(mktemp -d "$STATE_ROOT/build.XXXXXX")"
  pid="" ok=0 bundle_id="$ID_PREFIX-$RANDOM$RANDOM"
  local id="" sign="Triage Local Signing"
  printf '%s' "$bundle_id" >"$tmp/bundle-id"
  # Anything short of a printed pid ends the build: a half-started app must not be left running.
  trap 'if ((ok == 0)); then [[ -n "$pid" ]] && remove_build "$pid"; rm -rf "$tmp"; forget_settings "${bundle_id:-}"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local app="$tmp/Triage.app" log="$tmp/triage.log"
  TRIAGE_APP="$app" "$ROOT/scripts/bundle.sh" >&2
  # A second process with the installed app's bundle id (dev.rogal.triage) starts but opens no window.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
  # Changing the plist breaks the signature bundle.sh made. Sign with the same stable identity, as bundle.sh does: an ad hoc
  # signature differs on every run, so macOS asks again for each Keychain item the app reads (GitLab, Linear, Anthropic).
  security find-identity -p codesigning | grep -qF "\"$sign\"" || sign="-"
  codesign --force --sign "$sign" "$app" >/dev/null 2>&1

  # A scenario that does not load ends the app at once; say why now rather than after 60 s without a window.
  TRIAGE_FIXTURE="$scenario" "$app/Contents/MacOS/Triage" --check-fixture >/dev/null ||
    fail "bad mock scenario: $scenario"

  # Directly, never through `open`: the process is then ours, and what runs this can find it again. Its output goes to a
  # file and its input is empty, so nothing reading this command's output waits for it.
  TRIAGE_FIXTURE="$scenario" "$app/Contents/MacOS/Triage" >"$log" 2>&1 </dev/null &
  pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s' "$tmp" >"$PIDS/$pid"

  local info
  SECONDS=0  # wall clock: each lookup starts the Swift interpreter, so counting iterations would overrun 60 s
  while ((SECONDS < 60)); do
    kill -0 "$pid" 2>/dev/null || break
    if info="$(swift "$ROOT/scripts/window-info.swift" "$pid" 2>/dev/null)"; then
      read -r id _ <<<"$info"
      break
    fi
    sleep 0.5
  done
  if [[ -z "$id" ]]; then
    echo "Triage (pid $pid) showed no window within 60 s. End of its output:" >&2
    tail -n 40 "$log" >&2
    fail "no window"
  fi

  # Before the settle wait, so the first refresh lays out at the final size. A failure (no Accessibility) is a note: the
  # capture is then at the launch size.
  if ! TRIAGE_PID="$pid" swift "$ROOT/scripts/ax.swift" resize "${size%x*}" "${size#*x}" >&2; then
    echo "Could not resize the window (is Accessibility granted to this terminal?); it stays at the launch size." >&2
  fi
  local width="" height=""
  if info="$(swift "$ROOT/scripts/window-info.swift" "$pid" 2>/dev/null)"; then
    read -r id _ _ width height <<<"$info"
  fi
  sleep "${VERIFY_SETTLE_SECONDS:-3}"  # the first refresh reads the scenario: a moment for the list to lay out

  ok=1
  echo "pid=$pid"
  echo "window=$id"
  echo "size=${width}x${height}"
  echo "log=$log"
}

list() {
  local pid
  pid="$(resolve_pid "$1")"
  build_dir "$pid" >/dev/null
  TRIAGE_PID="$pid" swift "$ROOT/scripts/ax.swift"
}

press() {
  local pid label="${2:-}"
  pid="$(resolve_pid "$1")"
  build_dir "$pid" >/dev/null
  [[ -n "$label" ]] || fail "press needs a label"
  if [[ "$label" =~ $REFUSED ]]; then fail "refused: press $label (it acts on a forge, opens another app or costs money)"; fi
  # The check above is for a clear message; ax.swift checks the label the prefix resolves to.
  TRIAGE_PID="$pid" TRIAGE_REFUSE="$REFUSED" swift "$ROOT/scripts/ax.swift" press "$label"
}

shot() {
  local pid name="${2:-}" info id
  pid="$(resolve_pid "$1")"
  build_dir "$pid" >/dev/null
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "bad screenshot name: $name"
  : "${WORKBENCH_PROOF_DIR:?WORKBENCH_PROOF_DIR is not set}"
  [[ -d "$WORKBENCH_PROOF_DIR" ]] || mkdir -p "$WORKBENCH_PROOF_DIR"
  info="$(swift "$ROOT/scripts/window-info.swift" "$pid" 2>/dev/null)" || fail "pid $pid has no window on screen"
  read -r id _ <<<"$info"
  screencapture -x -o -l "$id" "$WORKBENCH_PROOF_DIR/$name.png"
  echo "$WORKBENCH_PROOF_DIR/$name.png"
}

stop() {
  local pid="$1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "not a pid: $pid"
  [[ -f "$PIDS/$pid" ]] || fail "pid $pid is not a build started by verify-app.sh start"
  remove_build "$pid"
  forget_settings
  echo "stopped $pid"
}

# What Workbench's `[run]` runs: the same build as `start`, held until Workbench ends it, so the process Workbench owns is the
# one that cleans up. `WORKBENCH_RUN_PID` is this script's pid, which is how `run` finds the build in the other commands.
serve() {
  start "$@"
  serve_file="$PIDS/serve-$$"
  printf '%s' "$pid" >"$serve_file"
  # `pid` is start's global: the build to remove, here and on any way out.
  trap 'remove_build "$pid"; forget_settings; rm -f "$serve_file"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  echo "Triage is up"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
  fail "the build ended on its own; its output is in $tmp/triage.log"
}

command="${1:-}"
case "$command" in
  start) shift; start "$@" ;;
  serve) shift; serve "$@" ;;
  list | press | shot | stop)
    shift
    [[ $# -ge 1 ]] || usage
    "$command" "$@"
    ;;
  *) usage ;;
esac
