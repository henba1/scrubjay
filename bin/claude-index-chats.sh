#!/usr/bin/env bash
# Build hosts/<host>/chats.index.json: a registry of which Claude projects/chats
# live on this machine. Indexes metadata only — never copies transcript contents.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJDIR="$CLAUDE_DIR/projects"
HOST=""
[ "${1:-}" = "--host" ] && { HOST="${2:?}"; shift 2; }

resolve_host() {
  [ -n "$HOST" ] && { echo "$HOST"; return; }
  [ -n "${CLAUDE_HOST:-}" ] && { echo "$CLAUDE_HOST"; return; }
  [ -f "$HOME/.config/dotclaude/host" ] && { cat "$HOME/.config/dotclaude/host"; return; }
  hostname -s
}
HOST="$(resolve_host)"
OUT="$REPO/hosts/$HOST/chats.index.json"
mkdir -p "$(dirname "$OUT")"

tmp="$(mktemp)"; echo "[]" > "$tmp"
shopt -s nullglob
for d in "$PROJDIR"/*/; do
  mapfile -t jsonls < <(find "$d" -maxdepth 1 -name '*.jsonl' -type f)
  [ "${#jsonls[@]}" -eq 0 ] && continue
  slug="$(basename "$d")"
  cwd=""
  for f in "${jsonls[@]}"; do
    cwd="$(jq -r 'select(.cwd != null) | .cwd' "$f" 2>/dev/null | head -1 || true)"
    [ -n "$cwd" ] && break
  done
  size="$(du -sh "$d" 2>/dev/null | cut -f1)"
  last_epoch="$(find "$d" -maxdepth 1 -name '*.jsonl' -printf '%T@\n' | sort -nr | head -1)"
  last="$(date -d "@${last_epoch%.*}" +%Y-%m-%d 2>/dev/null || echo unknown)"
  obj="$(jq -n \
    --arg slug "$slug" --arg cwd "$cwd" --argjson sessions "${#jsonls[@]}" \
    --arg size "$size" --arg last "$last" \
    '{project: (if $cwd=="" then $slug else ($cwd|split("/")|last) end),
      cwd: $cwd, slug: $slug, sessions: $sessions, size: $size, last: $last}')"
  jq --argjson o "$obj" '. += [$o]' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
done
mv "$tmp" "$OUT"
echo "wrote $OUT ($(jq length "$OUT") projects)"
