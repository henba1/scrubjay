#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# One-shot: ship every EXISTING session transcript to the relay AND index any that are
# missing from the catalogue. The SessionEnd hook only ships/indexes sessions that end
# after it went live; this backfills the back catalogue.
# Idempotent — re-running ships only new/changed files and skips already-indexed rows.
# Usage: [--host NAME]
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

# Index pass: write a catalogue row for every shipped transcript that has no entry yet.
# Runs after shipping so the archive and index stay consistent. Append-only and idempotent
# — sj_log_row's write-once guard (grep session=<sid>) makes re-runs safe. A failure here
# warns but does not abort, so a bad transcript never blocks the rest of the backfill.
DATA="$(sj_data 2>/dev/null || true)"
if [ -z "$DATA" ] || [ ! -d "$DATA" ]; then
  echo "backfill: no data repo found — skipping catalogue index" >&2
else
  LOG="$DATA/logs/$HOST.log"; mkdir -p "$DATA/logs"; touch "$LOG"
  harness="${SCRUBJAY_HARNESS:-claude}"
  indexed=0; skipped=0
  for f in "${files[@]}"; do
    sid="$(basename "$f" .jsonl)"
    cwd="$(basename "$(dirname "$f")")"
    mt="$(sj_mtime "$f")" || mt=""
    ts=""; [ -n "$mt" ] && ts="$(sj_epoch_stamp "$mt")"
    if sj_log_row "$LOG" "$sid" "$cwd" "$f" "$harness" "$HOST" "$ts" "" 2>/dev/null; then
      indexed=$((indexed + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  echo "catalogue index: $indexed new row(s), $skipped already present"
  if [ "$indexed" -gt 0 ]; then
    sj_data_push "backfill: index $indexed session(s) from $HOST" || true
  fi
fi
