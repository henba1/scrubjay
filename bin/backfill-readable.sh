#!/usr/bin/env bash
# One-off: build the human-readable Markdown `readable/` tree for transcripts already on the
# NAS. Run on the box that has the NAS mounted. Idempotent (re-renders, overwrites).
#   usage: backfill-readable.sh [chats-root]   (defaults to $SCRUBJAY_LOCAL_CHATS)
set -uo pipefail
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$APP/bin/lib.sh"; sj_load_config
root="${1:-${SCRUBJAY_LOCAL_CHATS:-}}"
[ -n "$root" ] && [ -d "$root" ] || { echo "usage: backfill-readable.sh <chats-root>" >&2; exit 1; }

n=0
while IFS= read -r f; do
  rel="${f#"$root"/}"; host="${rel%%/*}"          # <host>/<slug>/<sid>.jsonl
  sid="$(basename "$f" .jsonl)"
  out="$root/$host/readable/$(sj_readable_relpath "$f" "$sid").md"
  mkdir -p "$(dirname "$out")" || continue
  bash "$APP/bin/render-transcript.sh" "$f" > "$out" 2>/dev/null && n=$((n+1))
done < <(find "$root" -type f -name '*.jsonl' \
              ! -path '*/readable/*' ! -path '*/subagents/*' ! -name 'agent-*')
echo "rendered $n transcript(s) into */readable/ under $root"
