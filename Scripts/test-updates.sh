#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc "$ROOT/App/UpdateSupport.swift" "$ROOT/App/UpdateInstaller.swift" "$ROOT/App/UpdateManager.swift" "$ROOT/Tests/UpdateTests.swift" -o "$TEST_DIR/update-tests"
"$TEST_DIR/update-tests"
zsh "$ROOT/Scripts/test-update-installer.sh" "$TEST_DIR/update-tests"
