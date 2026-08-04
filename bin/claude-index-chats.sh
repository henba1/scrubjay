#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik. See LICENSE.

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
  # Newest transcript's date. Spelled out in three guarded steps rather than nested command
  # substitutions because this script runs under `set -e`: sj_mtime deliberately fails instead of
  # reporting a fabricated 0, and a bare assignment from a failing substitution would abort the
  # whole indexer — losing every remaining project — where one unknown date is the honest outcome.
  # The transcript can genuinely vanish between the glob above and here (a concurrent session end).
  newest="$(sj_ls_by_mtime "$d" '*.jsonl' 1 | head -1)"
  last_epoch=""; [ -n "$newest" ] && last_epoch="$(sj_mtime "$newest" 2>/dev/null || true)"
  last=unknown
  [ -n "$last_epoch" ] && last="$(sj_epoch_ymd "${last_epoch%.*}" 2>/dev/null || echo unknown)"
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
