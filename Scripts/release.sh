#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-}"

if [[ -z "$TAG" ]]; then
  echo "Uso: ./Scripts/release.sh v0.1.1-alpha" >&2
  exit 2
fi

if [[ "$TAG" != v* ]]; then
  echo "A versão deve começar com v. Ex.: v0.1.1-alpha" >&2
  exit 3
fi

cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Existem alterações não commitadas. Faça commit antes da release." >&2
  git status --short
  exit 4
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "A tag $TAG já existe." >&2
  exit 5
fi

echo "→ Validando código"
xcrun swiftc -parse-as-library -typecheck App/*.swift

echo "→ Atualizando main"
git push origin main

echo "→ Criando tag $TAG"
git tag -a "$TAG" -m "BottleForge $TAG"
git push origin "$TAG"

echo "✓ Deploy disparado"
echo "  GitHub Actions vai gerar e publicar a release automaticamente."
echo "  Acompanhe em: https://github.com/JGSimi/BottleForge/actions"
