#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-v0.1.0-alpha}"
APP="$ROOT/dist/BottleForge.app"
RELEASE_DIR="$ROOT/release"
STAGE="$RELEASE_DIR/stage"
DMG="$RELEASE_DIR/BottleForge-$TAG-macOS.dmg"

if [[ ! -d "$APP" ]]; then
  "$ROOT/Scripts/build-app.sh" "$TAG"
fi

echo "→ Preparando DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/BottleForge.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create   -volname "BottleForge"   -srcfolder "$STAGE"   -ov   -format UDZO   "$DMG"

echo "→ Calculando SHA-256"
HASH="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(stat -f%z "$DMG")"

echo "✓ Pacote pronto"
echo "  $DMG"
echo "  sha256:$HASH"
echo "  bytes:$SIZE"
