#!/usr/bin/env bash
# Everything CI runs, in the same order. Run before pushing: scripts/check.sh  (add --fix to auto-format first)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--fix" ]]; then
  echo "→ formatting"
  swift format -i -r Sources Tests Package.swift
  swiftlint lint --fix --quiet
fi

echo "→ lint (swift-format, warnings fail)"
swift format lint --strict -r Sources Tests Package.swift

echo "→ lint (SwiftLint, strict)"
command -v swiftlint >/dev/null || { echo "SwiftLint missing: brew install swiftlint"; exit 1; }
swiftlint lint --quiet

echo "→ build (Swift 6 strict concurrency, warnings as errors)"
swift build -Xswiftc -warnings-as-errors

echo "→ test + coverage (TriageCore, minimum in scripts/coverage.sh)"
scripts/coverage.sh

echo "✓ all checks passed"
