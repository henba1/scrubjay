#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# One-shot: ship every EXISTING session transcript to the relay, then catalogue the ones no row
# has ever been written for (via bin/sj-reconcile.sh). The SessionEnd hook only records sessions
# that end after it went live; this covers the back catalogue — both halves of it, since a shipped
# transcript with no catalogue row is archived but unfindable.
# Idempotent — re-running ships only new/changed files and writes no second row for a session.
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

# Index pass. Shipping alone leaves the back catalogue archived but invisible: /sjbrowse, /sjtable
# and /sjrecall all read logs/<host>.log, not the archive. bin/sj-reconcile.sh already writes that
# row for a session the catalogue has never heard of — reuse it rather than growing a second writer,
# since sj_log_row's format has three readers and a fourth author would drift. Delegating also buys
# the adapter-derived fields (real cwd, model, turns), the single-writer lock, and the catalogue
# re-render, none of which this loop would get for free.
#
# NOT --all, which lifts the liveness guard along with the age window. This script is run by hand
# from inside a live session, and cataloguing that session mid-flight would freeze its row at a
# partial turn count — the write-once guard means its real SessionEnd row is never written. So lift
# the age window explicitly and leave --quiet-mins doing its job. --max is needed because the cap
# only lifts on the --all path.
#
# NOSHIP: everything above is already shipped. A failure here warns; the backfill still succeeded.
SCRUBJAY_HARNESS=claude SCRUBJAY_NOSHIP=1 \
  "$APP/bin/sj-reconcile.sh" --within-days 36500 --quiet-mins 30 --max 100000 \
  || echo "backfill: catalogue index failed — run bin/sj-reconcile.sh --all by hand" >&2
