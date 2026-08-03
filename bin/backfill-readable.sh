#!/usr/bin/env bash
# One-off: build the human-readable Markdown `readable/` tree for transcripts already on the
# NAS. Run on the box that has the NAS mounted. Idempotent (re-renders, overwrites).
#
#   usage: backfill-readable.sh [--no-prune] [chats-root]   (root defaults to $SCRUBJAY_LOCAL_CHATS)
#
# It also PRUNES stale duplicates: an earlier naming scheme dated the readable file from the
# transcript's mtime, so one session could end up under two dates — a `/sjlog` either side of
# midnight, or a re-render off an archived copy whose mtime was the time it was shipped rather than
# the time the session ran. The older file is a truncated copy of the same conversation under the
# same `__<sid8>` handle, which is the thing every reader treats as a session identifier. Now that
# the date comes from the transcript's own records (sj_transcript_date), the name is stable, and a
# stale sibling can be recognised and dropped: same topic, same handle, different date. Nothing else
# is ever removed — a name that does not match on BOTH topic and handle is left alone. --no-prune
# renders without deleting anything.
set -uo pipefail
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$APP/bin/lib.sh"; sj_load_config

PRUNE=1
case "${1:-}" in --no-prune) PRUNE=0; shift ;; esac
root="${1:-${SCRUBJAY_LOCAL_CHATS:-}}"
[ -n "$root" ] && [ -d "$root" ] || { echo "usage: backfill-readable.sh [--no-prune] <chats-root>" >&2; exit 1; }

n=0; pruned=0
while IFS= read -r f; do
  rel="${f#"$root"/}"; host="${rel%%/*}"          # <host>/<slug>/<sid>.jsonl
  sid="$(basename "$f" .jsonl)"
  relout="$(sj_readable_relpath "$f" "$sid")"     # <project>/<date>_<topic>__<sid8>
  out="$root/$host/readable/$relout.md"
  dir="$(dirname "$out")"
  mkdir -p "$dir" || continue
  bash "$APP/bin/render-transcript.sh" "$f" > "$out" 2>/dev/null && n=$((n+1)) || continue

  # Drop any earlier name for THIS session: same `<topic>__<handle>`, different date. Matching on
  # the handle alone would be enough in practice but not safe in principle — two sessions can share
  # an 8-char prefix — so the topic has to match too, and a file whose topic differs survives.
  [ "$PRUNE" = 1 ] || continue
  stem="$(basename "$relout")"; stem="${stem#*_}"   # strip the leading <date>_
  for old in "$dir"/*_"$stem".md; do
    [ -e "$old" ] || continue
    [ "$old" = "$out" ] && continue
    rm -f -- "$old" && pruned=$((pruned+1))
  done
done < <(find "$root" -type f -name '*.jsonl' \
              ! -path '*/readable/*' ! -path '*/subagents/*' ! -name 'agent-*')
printf 'rendered %d transcript(s) into */readable/ under %s' "$n" "$root"
[ "$pruned" -gt 0 ] && printf ' (pruned %d stale duplicate(s) from the old mtime-based naming)' "$pruned"
printf '\n'
