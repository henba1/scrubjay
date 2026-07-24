#!/usr/bin/env bash
# One-shot: ship every EXISTING session transcript to the relay. The SessionEnd hook
# only ships sessions that end after it went live; this uploads the back catalogue.
# Idempotent — re-running ships only new/changed files. Usage: [--host NAME]
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJDIR="$CLAUDE_DIR/projects"
[ "${1:-}" = "--host" ] && { CLAUDE_HOST="${2:?}"; export CLAUDE_HOST; shift 2; }
HOST="$(sj_host)"
backend="${SCRUBJAY_TRANSCRIPT_BACKEND:-git}"

# Top-level session transcripts only (projects/<slug>/<session>.jsonl) — same set the
# hook ships; excludes nested subagent transcripts.
mapfile -t files < <(find "$PROJDIR" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null | sort)
echo "found ${#files[@]} transcripts under $PROJDIR  (host=$HOST, backend=$backend)"
[ "${#files[@]}" -gt 0 ] || exit 0

if [ "$backend" = "git" ]; then
  chats="$(sj_chats)"
  [ -n "$chats" ] && [ -d "$chats/.git" ] || { echo "no chats repo at '$chats'" >&2; exit 1; }
  for f in "${files[@]}"; do
    slug="$(basename "$(dirname "$f")")"; sid="$(basename "$f" .jsonl)"
    dst="$chats/$HOST/$slug/$sid.jsonl"
    mkdir -p "$(dirname "$dst")"; cp -f "$f" "$dst"
  done
  cd "$chats" || { echo "backfill: cannot cd into '$chats'" >&2; exit 1; }
  git add -A
  if git diff --cached --quiet; then
    echo "relay already up to date — nothing to push"
  else
    added="$(git diff --cached --numstat | wc -l)"
    git commit -q -m "backfill: $added transcripts from $HOST"
    if sj_timeout 180 git push -q; then echo "pushed $added transcripts to scrubjay-chats"
    else echo "committed; push failed (goes out on next push)"; fi
  fi
else
  # transport-agnostic fallback (e.g. rsync-wg): ship each via the configured backend
  for f in "${files[@]}"; do
    slug="$(basename "$(dirname "$f")")"; sid="$(basename "$f" .jsonl)"
    "$APP/bin/ship-transcript.sh" "$f" "$slug" "$sid" "$HOST" || true
  done
  echo "shipped ${#files[@]} transcripts via $backend"
fi
