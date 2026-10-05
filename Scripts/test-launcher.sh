#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/LauncherTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LauncherTests</string>
<key>CFBundleIdentifier</key><string>app.bottleforge.launcher-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>BottleForgeReleaseTag</key><string>v0.0.0-test</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -D BOTTLEFORGE_LAUNCHER_TESTS "$ROOT"/App/*.swift "$ROOT/Tests/LauncherTests.swift" -o "$APP/Contents/MacOS/LauncherTests"
BOTTLEFORGE_SUPPORT_ROOT="$TEST_DIR/User Data" "$APP/Contents/MacOS/LauncherTests"
