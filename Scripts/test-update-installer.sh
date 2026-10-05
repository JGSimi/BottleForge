#!/bin/zsh
set -euo pipefail
TEST_BINARY="$1"
TEST_ROOT="$(mktemp -d /tmp/BottleForgeUpdaterTest.XXXXXX)"
RUN_PID=""
INSTALL_PID=""
cleanup() {
  [[ -z "$RUN_PID" ]] || kill "$RUN_PID" 2>/dev/null || true
  [[ -z "$INSTALL_PID" ]] || kill "$INSTALL_PID" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
make_app() {
  local app="$1" tag="$2"
  mkdir -p "$app/Contents/MacOS"
  cp /usr/bin/true "$app/Contents/MacOS/BottleForge"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.bottleforge.BottleForge</string>
<key>CFBundleExecutable</key><string>BottleForge</string>
<key>CFBundleName</key><string>BottleForge Updater Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.12</string>
<key>BottleForgeReleaseTag</key><string>$tag</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --deep --sign - "$app" 2>/dev/null
}
make_image() {
  local destination="$1"
  hdiutil create -quiet -volname BottleForgeUpdaterTest -srcfolder "$TEST_ROOT/image" -format UDZO "$destination"
}
launch_installer() {
  local dmg="$1" target="$2" tag="$3" state="$4"
  mkdir -p "$state"
  /bin/sleep 120 &
  RUN_PID=$!
  "$TEST_BINARY" --emit-installer "$RUN_PID" "$dmg" "$target" "$tag" "$state" > "$state/install.sh"
  /bin/zsh "$state/install.sh" > "$state/installer.log" 2>&1 &
  INSTALL_PID=$!
}
wait_for_ready() {
  local state="$1"
  for _ in {1..300}; do
    [[ ! -e "$state/ready" ]] || return 0
    kill -0 "$INSTALL_PID" 2>/dev/null || { cat "$state/installer.log"; fail "Installer failed before readiness"; }
    sleep 0.1
  done
  fail "Installer did not reach readiness"
}
stop_fixture() {
  kill "$RUN_PID"
  wait "$RUN_PID" 2>/dev/null || true
  RUN_PID=""
}
installed_tag() { /usr/libexec/PlistBuddy -c 'Print :BottleForgeReleaseTag' "$1/Contents/Info.plist"; }

PARENT="$TEST_ROOT/Apps with spaces'quotes"
TARGET="$PARENT/BottleForge.app"
mkdir -p "$PARENT" "$TEST_ROOT/image"
make_app "$TEST_ROOT/image/BottleForge.app" v0.1.12-alpha
make_app "$TARGET" v0.1.11-alpha

# Verify the full production installer with a real signed app and mounted DMG.
make_image "$TEST_ROOT/success.dmg"
launch_installer "$TEST_ROOT/success.dmg" "$TARGET" v0.1.12-alpha "$TEST_ROOT/state/success"
wait_for_ready "$TEST_ROOT/state/success"
[[ "$(installed_tag "$TARGET")" == v0.1.11-alpha ]] || fail "App changed before graceful shutdown"
stop_fixture
wait "$INSTALL_PID" || { cat "$TEST_ROOT/state/success/installer.log"; fail "Successful installation failed"; }
INSTALL_PID=""
[[ "$(installed_tag "$TARGET")" == v0.1.12-alpha ]] || fail "New version was not installed"
codesign --verify --deep --strict "$TARGET"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :code' "$TEST_ROOT/state/success/result.plist")" == 0 ]] || fail "Success was not persisted"

# A mismatched release must fail before requesting shutdown or replacing the app.
make_image "$TEST_ROOT/wrong-tag.dmg"
launch_installer "$TEST_ROOT/wrong-tag.dmg" "$TARGET" v0.1.13-alpha "$TEST_ROOT/state/wrong-tag"
if wait "$INSTALL_PID"; then fail "Mismatched tag was accepted"; fi
INSTALL_PID=""
kill -0 "$RUN_PID" || fail "Preflight failure terminated the running app"
stop_fixture
[[ ! -e "$TEST_ROOT/state/wrong-tag/ready" ]] || fail "Mismatched tag requested shutdown"
[[ "$(installed_tag "$TARGET")" == v0.1.12-alpha ]] || fail "Preflight failure changed the installed app"

# Corrupt the staged copy after verification, reproducing a post-swap failure.
make_image "$TEST_ROOT/rollback.dmg"
launch_installer "$TEST_ROOT/rollback.dmg" "$TARGET" v0.1.12-alpha "$TEST_ROOT/state/rollback"
wait_for_ready "$TEST_ROOT/state/rollback"
staged=("$PARENT"/.BottleForgeUpdate.*/BottleForge.app/Contents/Info.plist(N))
[[ "${#staged}" == 1 ]] || fail "Could not locate isolated staging bundle"
/usr/libexec/PlistBuddy -c 'Set :BottleForgeReleaseTag corrupted' "$staged[1]"
stop_fixture
if wait "$INSTALL_PID"; then fail "Corrupted staged app was accepted"; fi
INSTALL_PID=""
[[ "$(installed_tag "$TARGET")" == v0.1.12-alpha ]] || fail "Rollback did not restore the previous version"
codesign --verify --deep --strict "$TARGET"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :code' "$TEST_ROOT/state/rollback/result.plist")" != 0 ]] || fail "Rollback failure was not persisted"
echo "Real DMG installation, preflight rejection and rollback tests passed"
