#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_ROOT="${BOTTLEFORGE_D3D12_CACHE:-/tmp/bottleforge-d3d12-runtime-cache}"
RUNTIME="$ROOT/Runtime/D3D12"

VERSION="v1.0"
ARCHIVE="vkd3d-proton-macos.tar.zst"
URL="https://github.com/metalsharp/VKD3D-Proton-MacOS/releases/download/$VERSION/$ARCHIVE"
ARCHIVE_SHA256="f1eabd729a65f0a62bcba9a3a8054bdef9895981351dc8896993a8cffa12299c"

mkdir -p "$CACHE_ROOT"
FILE="$CACHE_ROOT/$ARCHIVE"

download_verified() {
  local url="$1" expected="$2" output="$3"

  if [[ -f "$output" ]]; then
    local actual="$(shasum -a 256 "$output" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] && return
    rm -f "$output"
  fi

  curl -L --fail --retry 3 --retry-delay 2 "$url" -o "$output"
  local actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "SHA-256 inválido para $output" >&2
    exit 60
  }
}

if ! command -v zstd >/dev/null 2>&1; then
  echo "zstd não encontrado" >&2
  exit 61
fi

echo "→ Preparando runtime D3D12"
download_verified "$URL" "$ARCHIVE_SHA256" "$FILE"

TMP="$CACHE_ROOT/extracted"
rm -rf "$TMP" "$RUNTIME"
mkdir -p "$TMP" "$RUNTIME"

zstd -dc "$FILE" | tar -xf - -C "$TMP"
SRC="$TMP/vkd3d-proton-macos"

for file in dxgi.dll d3d12.dll d3d12core.dll libMoltenVK.dylib MoltenVK_icd.json README.md SHA256SUMS; do
  test -f "$SRC/$file" || {
    echo "Arquivo ausente no runtime D3D12: $file" >&2
    exit 62
  }
done

cp "$SRC/"{dxgi.dll,d3d12.dll,d3d12core.dll,libMoltenVK.dylib,MoltenVK_icd.json,README.md,SHA256SUMS} "$RUNTIME/"

(
  cd "$RUNTIME"
  shasum -a 256 -c SHA256SUMS
)

codesign --verify "$RUNTIME/libMoltenVK.dylib" 2>/dev/null || true

echo "✓ Runtime D3D12 pronto"
du -sh "$RUNTIME"
