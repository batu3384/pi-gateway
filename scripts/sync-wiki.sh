#!/usr/bin/env bash
# Sync wiki/ markdown to GitHub Wiki (.wiki.git).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WIKI_SRC="$PROJECT_DIR/wiki"
REPO="${GITHUB_REPOSITORY:-}"

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
[[ -n "$REPO" ]] || {
  echo "[sync-wiki] HATA: GITHUB_REPOSITORY veya gh repo context gerekli" >&2
  exit 1
}
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "[sync-wiki] HATA: gecersiz repo: $REPO" >&2
  exit 1
}

command -v gh >/dev/null 2>&1 || {
  echo "[sync-wiki] HATA: gh CLI gerekli" >&2
  exit 1
}

command -v rsync >/dev/null 2>&1 || {
  echo "[sync-wiki] HATA: rsync gerekli" >&2
  exit 1
}

[[ -d "$WIKI_SRC" ]] || {
  echo "[sync-wiki] HATA: $WIKI_SRC yok" >&2
  exit 1
}

WIKI_URL="https://github.com/${REPO}.wiki.git"
WIKI_WEB="https://github.com/${REPO}/wiki"
WIKI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-gateway-wiki.XXXXXX")"
cleanup() { rm -rf "$WIKI_DIR"; }
trap cleanup EXIT

log() { echo "[sync-wiki] $*"; }

gh auth setup-git >/dev/null 2>&1 || true

clone_err=""
if ! clone_err="$(git clone "$WIKI_URL" "$WIKI_DIR" 2>&1)"; then
  if [[ "$clone_err" == *"Repository not found"* || "$clone_err" == *"not found"* ]]; then
    log "Wiki git henuz yok (ilk sayfa GitHub UI'dan gerekli)."
    log "1) Ac: ${WIKI_WEB}/_new"
    log "2) Baslik: Home — kisa bir satir kaydet"
    log "3) Tekrar: $0"
    exit 2
  fi
  echo "[sync-wiki] HATA: git clone basarisiz:" >&2
  echo "$clone_err" >&2
  exit 1
fi

rsync -av --delete \
  --exclude='.git/' \
  --exclude='README.md' \
  "$WIKI_SRC/" "$WIKI_DIR/"

cd "$WIKI_DIR"
git add -A

if git diff --staged --quiet; then
  log "Degisiklik yok — wiki guncel"
  log "URL: $WIKI_WEB"
  exit 0
fi

git -c user.name="${GIT_AUTHOR_NAME:-pi-gateway sync}" \
  -c user.email="${GIT_AUTHOR_EMAIL:-pi-gateway-sync@users.noreply.github.com}" \
  commit -m "Sync wiki from pi-gateway ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
git push origin HEAD:master
log "Push OK"
log "URL: $WIKI_WEB"
