#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc "$ROOT/App/GameCompatibility.swift" "$ROOT/App/SteamLibraries.swift" "$ROOT/App/LayaProfileEngine.swift" "$ROOT/Tests/CompatibilityTests.swift" -o "$TEST_DIR/compatibility-tests"
"$TEST_DIR/compatibility-tests"
