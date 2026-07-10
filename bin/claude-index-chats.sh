#!/usr/bin/env bash
# Build <data>/hosts/<host>/chats.index.json: a registry of which Claude projects/chats
# live on this machine. Indexes metadata only — never copies transcript contents.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJDIR="$CLAUDE_DIR/projects"
[ "${1:-}" = "--host" ] && { CLAUDE_HOST="${2:?}"; export CLAUDE_HOST; shift 2; }

HOST="$(sj_host)"
DATA="$(sj_data)"
OUT="$DATA/hosts/$HOST/chats.index.json"
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
  tdir="${d%/}"; tdir="${tdir/#$HOME/~}"
  obj="$(jq -n \
    --arg slug "$slug" --arg cwd "$cwd" --argjson sessions "${#jsonls[@]}" \
    --arg size "$size" --arg last "$last" --arg tdir "$tdir" \
    '{project: (if $cwd=="" then $slug else ($cwd|split("/")|last) end),
      cwd: $cwd, slug: $slug, sessions: $sessions, size: $size, last: $last,
      transcripts_dir: $tdir}')"
  jq --argjson o "$obj" '. += [$o]' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
done
mv "$tmp" "$OUT"
echo "wrote $OUT ($(jq length "$OUT") projects)"
