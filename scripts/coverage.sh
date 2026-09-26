#!/usr/bin/env bash
# Runs the tests with coverage and reports line coverage for TriageCore (the unit-tested logic; the SwiftUI
# app target isn't unit-tested). Fails if total line coverage is below the minimum.
#   scripts/coverage.sh              # test + report + gate
#   COVERAGE_MIN=70 scripts/coverage.sh   # stricter one-off
set -euo pipefail
cd "$(dirname "$0")/.."

MIN="${COVERAGE_MIN:-60}"

swift test --enable-code-coverage -Xswiftc -warnings-as-errors

BIN_DIR="$(swift build --show-bin-path)"
BIN="$BIN_DIR/TriagePackageTests.xctest/Contents/MacOS/TriagePackageTests"
PROF="$BIN_DIR/codecov/default.profdata"

REPORT="$(xcrun llvm-cov report "$BIN" -instr-profile "$PROF" Sources/TriageCore | sed "s#$PWD/Sources/TriageCore/##")"
echo "$REPORT"

PCT="$(xcrun llvm-cov export -summary-only "$BIN" -instr-profile "$PROF" Sources/TriageCore |
  python3 -c 'import json, sys; d = json.load(sys.stdin); print("%.1f" % d["data"][0]["totals"]["lines"]["percent"])')"
echo "TriageCore line coverage: ${PCT}% (minimum ${MIN}%)"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### TriageCore line coverage: ${PCT}% (minimum ${MIN}%)"; echo '```'; echo "$REPORT"; echo '```'; } \
    >> "$GITHUB_STEP_SUMMARY"
fi

python3 -c "import sys; sys.exit(0 if float('$PCT') >= float('$MIN') else 1)" || {
  echo "✗ coverage ${PCT}% is below the ${MIN}% minimum"
  exit 1
}
