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

created=0
for attempt in 1 2 3; do
  rm -f "$DMG"

  if hdiutil create     -volname "BottleForge"     -srcfolder "$STAGE"     -ov     -format UDZO     "$DMG"; then
    created=1
    break
  fi

  echo "Tentativa $attempt de 3 falhou ao criar o DMG." >&2
  sleep $((attempt * 3))
done

if [[ "$created" -ne 1 ]]; then
  echo "Não foi possível criar o DMG após 3 tentativas." >&2
  exit 20
fi

echo "→ Calculando SHA-256"
HASH="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(stat -f%z "$DMG")"

echo "✓ Pacote pronto"
echo "  $DMG"
echo "  sha256:$HASH"
echo "  bytes:$SIZE"
