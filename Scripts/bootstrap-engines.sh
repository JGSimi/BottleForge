#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_ROOT="$ROOT/Engine"
CACHE_ROOT="${BOTTLEFORGE_ENGINE_CACHE:-/tmp/bottleforge-engine-cache}"
WORK_ROOT="$CACHE_ROOT/work"

WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.8/wine-staging-11.8-osx64.tar.xz"
WINE_SHA256="3ab51478ab609e6b0be588385a6f0f877842943f6037a3f32c999b829c1179ab"

PATCHED_WINE_URL="https://github.com/zzzz465/homebrew-wine-dxmt/releases/download/v11.8_mm1/wine-staging-11.8_mm1-osx64.tar.xz"
PATCHED_WINE_SHA256="236e517c12b8adf2092607742c4337632f7b03ffc06e4341bc5fc0a8f0160a9f"

DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
DXMT_SHA256="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"

download_verified() {
  local url="$1"
  local expected="$2"
  local output="$3"

  if [[ -f "$output" ]]; then
    local cached
    cached="$(shasum -a 256 "$output" | awk '{print $1}')"
    if [[ "$cached" == "$expected" ]]; then
      echo "✓ Cache válido: $(basename "$output")"
      return
    fi
    rm -f "$output"
  fi

  echo "→ Baixando $(basename "$output")"
  curl -L --fail --retry 3 --retry-delay 2 "$url" -o "$output"

  local actual
  actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA-256 inválido para $output" >&2
    echo "Esperado: $expected" >&2
    echo "Obtido:  $actual" >&2
    exit 40
  fi
}

mkdir -p "$CACHE_ROOT" "$WORK_ROOT"

WINE_ARCHIVE="$CACHE_ROOT/wine-staging-11.8-osx64.tar.xz"
PATCHED_WINE_ARCHIVE="$CACHE_ROOT/wine-staging-11.8-mm1-osx64.tar.xz"
DXMT_ARCHIVE="$CACHE_ROOT/dxmt-v0.80-builtin.tar.gz"

download_verified "$WINE_URL" "$WINE_SHA256" "$WINE_ARCHIVE"
download_verified "$PATCHED_WINE_URL" "$PATCHED_WINE_SHA256" "$PATCHED_WINE_ARCHIVE"
download_verified "$DXMT_URL" "$DXMT_SHA256" "$DXMT_ARCHIVE"

rm -rf "$WORK_ROOT/base" "$WORK_ROOT/patched" "$WORK_ROOT/dxmt"
mkdir -p "$WORK_ROOT/base" "$WORK_ROOT/patched" "$WORK_ROOT/dxmt"

echo "→ Extraindo Wine 11.8"
tar -xJf "$WINE_ARCHIVE" -C "$WORK_ROOT/base"
tar -xJf "$PATCHED_WINE_ARCHIVE" -C "$WORK_ROOT/patched"

echo "→ Extraindo DXMT 0.80"
tar -xzf "$DXMT_ARCHIVE" -C "$WORK_ROOT/dxmt"

BASE_APP="$WORK_ROOT/base/Wine Staging.app"
PATCHED_APP="$WORK_ROOT/patched/Wine Staging.app"
DXMT_DIR="$WORK_ROOT/dxmt/v0.80"

test -d "$BASE_APP"
test -d "$PATCHED_APP"
test -d "$DXMT_DIR"

rm -rf "$ENGINE_ROOT/wine-11.8-dxmt" "$ENGINE_ROOT/wine-11.8-wined3d"
mkdir -p "$ENGINE_ROOT"

echo "→ Montando engine WineD3D"
ditto "$BASE_APP" "$ENGINE_ROOT/wine-11.8-wined3d"

echo "→ Montando engine DXMT"
ditto "$BASE_APP" "$ENGINE_ROOT/wine-11.8-dxmt"

DXMT_WINE="$ENGINE_ROOT/wine-11.8-dxmt/Contents/Resources/wine"
PATCHED_WINE="$PATCHED_APP/Contents/Resources/wine"

echo "→ Aplicando adapter winemac para DXMT"
cp -f   "$PATCHED_WINE/lib/wine/x86_64-unix/winemac.so"   "$DXMT_WINE/lib/wine/x86_64-unix/winemac.so"

echo "→ Integrando DXMT 0.80 oficial"
for arch in x86_64-unix x86_64-windows i386-windows; do
  if [[ -d "$DXMT_DIR/$arch" && -d "$DXMT_WINE/lib/wine/$arch" ]]; then
    cp -f "$DXMT_DIR/$arch/"* "$DXMT_WINE/lib/wine/$arch/"
  fi
done

echo "→ Validando engines"
test -x "$ENGINE_ROOT/wine-11.8-dxmt/Contents/Resources/wine/bin/wine"
test -x "$ENGINE_ROOT/wine-11.8-wined3d/Contents/Resources/wine/bin/wine"
file "$ENGINE_ROOT/wine-11.8-dxmt/Contents/Resources/wine/bin/wine"
file "$ENGINE_ROOT/wine-11.8-wined3d/Contents/Resources/wine/bin/wine"

if ! nm -g "$DXMT_WINE/lib/wine/x86_64-unix/winemac.so" | grep -q '_macdrv_functions'; then
  echo "winemac.so não exporta macdrv_functions; DXMT não conseguirá criar Metal views." >&2
  exit 41
fi

test -f "$DXMT_WINE/lib/wine/x86_64-unix/winemetal.so"
test -f "$DXMT_WINE/lib/wine/x86_64-windows/d3d11.dll"
test -f "$DXMT_WINE/lib/wine/x86_64-windows/dxgi.dll"

echo "✓ Engines prontas"
du -sh "$ENGINE_ROOT/wine-11.8-dxmt" "$ENGINE_ROOT/wine-11.8-wined3d"
