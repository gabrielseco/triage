#!/usr/bin/env bash
# Everything CI runs, in the same order. Run before pushing: scripts/check.sh  (add --fix to auto-format first)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--fix" ]]; then
  echo "→ formatting"
  swift format -i -r Sources Tests Package.swift
fi

echo "→ lint (swift-format, warnings fail)"
swift format lint --strict -r Sources Tests Package.swift

echo "→ build (Swift 6 strict concurrency, warnings as errors)"
swift build -Xswiftc -warnings-as-errors

echo "→ test"
swift test -Xswiftc -warnings-as-errors

echo "✓ all checks passed"
