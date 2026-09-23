#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-v0.1.0-alpha}"
VERSION="${TAG#v}"
SHORT_VERSION="${VERSION%%-*}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

APP="$ROOT/dist/BottleForge.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
ENGINES="$RESOURCES/Engines"
STEAM_COMPAT="$RESOURCES/SteamCompat"
required=(
  "$ROOT/Engine/wine-11.8-dxmt"
  "$ROOT/Engine/wine-11.8-wined3d"
  "$ROOT/Runtime/Laya"
)

for requiredPath in "${required[@]}"; do
  if [[ ! -d "$requiredPath" ]]; then
    echo "Engine ausente: $requiredPath" >&2
    exit 10
  fi
done

echo "→ Compilando BottleForge $TAG"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$ENGINES" "$RESOURCES/Licenses" "$STEAM_COMPAT"

xcrun swiftc   -parse-as-library   -target arm64-apple-macos14.0   "$ROOT"/App/*.swift   -o "$CONTENTS/MacOS/BottleForge"

chmod +x "$CONTENTS/MacOS/BottleForge"

if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "x86_64-w64-mingw32-gcc não encontrado (instale mingw-w64)." >&2
  exit 11
fi

echo "→ Compilando correção CEF da Steam"
x86_64-w64-mingw32-gcc \
  -O2 -municode \
  "$ROOT/Tools/steamwebhelper-wrapper.c" \
  -o "$STEAM_COMPAT/steamwebhelper-wrapper.exe" \
  -static -lshell32 -mwindows

echo "→ Copiando runtimes"
ditto "$ROOT/Engine/wine-11.8-dxmt" "$ENGINES/wine-11.8-dxmt"
ditto "$ROOT/Engine/wine-11.8-wined3d" "$ENGINES/wine-11.8-wined3d"

echo "→ Copiando runtime Laya"
ditto "$ROOT/Runtime/Laya" "$RESOURCES/LayaRuntime"

ditto "$ROOT/ThirdPartyLicenses" "$RESOURCES/Licenses"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>BottleForge</string>
  <key>CFBundleExecutable</key>
  <string>BottleForge</string>
  <key>CFBundleIdentifier</key>
  <string>app.bottleforge.BottleForge</string>
  <key>CFBundleName</key>
  <string>BottleForge</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>BottleForgeReleaseTag</key>
  <string>$TAG</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Build pronta: $APP"
echo "  Release tag: $TAG"
echo "  Version: $SHORT_VERSION ($BUILD_NUMBER)"
