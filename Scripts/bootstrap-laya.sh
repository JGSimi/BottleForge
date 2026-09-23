#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_ROOT="${BOTTLEFORGE_LAYA_CACHE:-/tmp/bottleforge-laya-runtime-cache}"
RUNTIME="$ROOT/Runtime/Laya"

NODE_VERSION="22.23.2"
NODE_ARCHIVE="node-v$NODE_VERSION-darwin-arm64.tar.gz"
NODE_URL="https://nodejs.org/dist/v$NODE_VERSION/$NODE_ARCHIVE"
NODE_SHA256="61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6"

mkdir -p "$CACHE_ROOT"
ARCHIVE="$CACHE_ROOT/$NODE_ARCHIVE"

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
    exit 50
  }
}

echo "→ Preparando runtime Laya"
download_verified "$NODE_URL" "$NODE_SHA256" "$ARCHIVE"

rm -rf "$RUNTIME" "$CACHE_ROOT/node"
mkdir -p "$RUNTIME" "$CACHE_ROOT/node"
tar -xzf "$ARCHIVE" -C "$CACHE_ROOT/node"

NODE_ROOT="$CACHE_ROOT/node/node-v$NODE_VERSION-darwin-arm64"
cp "$NODE_ROOT/bin/node" "$RUNTIME/node"
cp "$NODE_ROOT/LICENSE" "$RUNTIME/NODE-LICENSE.txt"
chmod +x "$RUNTIME/node"

cp "$ROOT/LayaRuntime/package.json" "$RUNTIME/package.json"
cp "$ROOT/LayaRuntime/package-lock.json" "$RUNTIME/package-lock.json"
cp "$ROOT/LayaRuntime/choose-profile.mjs" "$RUNTIME/choose-profile.mjs"

echo "→ Instalando @receptron/laya"
cd "$RUNTIME"
npm ci --omit=dev --no-audit --no-fund
cp "$RUNTIME/node_modules/@receptron/laya/LICENSE" "$RUNTIME/LAYA-LICENSE.txt"
cp "$RUNTIME/node_modules/@huggingface/tokenizers/LICENSE" "$RUNTIME/HF-TOKENIZERS-LICENSE.txt"

# O pacote do ONNX Runtime traz binários de várias plataformas.
# BottleForge é arm64, então mantemos somente Darwin arm64.
ORT="$RUNTIME/node_modules/onnxruntime-node/bin/napi-v6"
if [[ -d "$ORT" ]]; then
  rm -rf "$ORT/linux" "$ORT/win32"
  if [[ -d "$ORT/darwin/x64" ]]; then
    rm -rf "$ORT/darwin/x64"
  fi
fi

test -x "$RUNTIME/node"
test -f "$RUNTIME/node_modules/@receptron/laya/dist/index.js"
test -f "$RUNTIME/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/onnxruntime_binding.node"

file "$RUNTIME/node"
file "$RUNTIME/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/onnxruntime_binding.node"

echo "✓ Laya runtime pronto"
du -sh "$RUNTIME"
