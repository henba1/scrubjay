#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Write a NOTE — a durable, long-form document produced during a session (an analysis, a briefing,
# a design rationale) — into the cross-machine store, and publish it immediately.
#
#   usage: sj-note.sh [--topic <text>] [--project <key>] [--from <file>] [--no-push]
#          (body on stdin unless --from is given)
#
# WHY THIS EXISTS. An agent asked for a written artefact had two places to put it, and both were
# wrong: the session scratchpad under /tmp (ephemeral, machine-local, and you have to go find it),
# or auto-memory (which is indexed by MEMORY.md and therefore loaded into the context of EVERY
# future session — fine for a one-line fact, a permanent tax for a two-page document).
#
# WHERE IT GOES.  <mem>/<project>/notes/<date>_<topic>__<sid8>.md
#
# That is a subdirectory of the per-project auto-memory dir, and the choice is load-bearing in three
# ways:
#   - it rides the memory GIT repo, not the rsync archive, so a note can be edited later on any
#     machine and actually merge (the archive is one-way by design and would silently clobber);
#   - custody is unchanged from memory's — a bare repo on the user's own NAS for the local/rsync-wg
#     backends, so a note holding sensitive analysis never touches a third party;
#   - Claude Code loads only MEMORY.md at session start; sibling topic files and subdirectories are
#     read on demand. So a note is durable and searchable WITHOUT costing context until it is asked
#     for. That is the whole distinction between a note and a memory.
#
# The `__<sid8>` suffix backlinks the note to the session that produced it, so /sjbrowse can offer
# the originating conversation. It is omitted when no live session can be resolved (a note written
# from a plain shell is still a perfectly good note).
#
# Reading them back is sjmcp's job (type=note in sj_list/sj_recall); this script only writes.
set -uo pipefail

# App root — `cd -P` so a symlinked caller resolves to the real app repo. Never `readlink -f`:
# that's GNU-only (see the portability shims at the top of bin/lib.sh, and AGENTS.md).
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh"; sj_load_config

die() { printf '\033[1;31m✗\033[0m sj-note: %s\n' "$*" >&2; exit 1; }

topic=""; project=""; from=""; push=1
while [ $# -gt 0 ]; do
  case "$1" in
    --topic)   topic="${2:-}"; shift 2 ;;
    --project) project="${2:-}"; shift 2 ;;
    --from)    from="${2:-}"; shift 2 ;;
    --no-push) push=0; shift ;;
    -h|--help) sed -n '8,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -)         shift ;;
    *)         die "unknown argument '$1' (see --help)" ;;
  esac
done

MEM="$(sj_memory)"
[ -n "$MEM" ] || die "SCRUBJAY_MEMORY is unset — run bin/onboard-memory.sh (or /sjmemory) first"

# ---- body ------------------------------------------------------------------------------------
# --from promotes a file that already exists (typically something written to the session scratchpad
# before anyone thought about where it should live). It COPIES: the source may still be open in an
# editor, and the scratchpad cleans itself up anyway.
body="$(mktemp)" || die "cannot create a temp file"
trap 'rm -f "$body"' EXIT
if [ -n "$from" ]; then
  [ -f "$from" ] || die "no such file: $from"
  cat -- "$from" > "$body" || die "cannot read $from"
else
  cat > "$body"
fi
[ -s "$body" ] || die "empty note (pass --from <file>, or pipe the body in on stdin)"

# ---- name ------------------------------------------------------------------------------------
# Topic: what the caller said, else the document's own first heading — the same rule
# sj_normalize_plans uses on a plan, so a note and a plan read alike in a listing.
[ -n "$topic" ] || topic="$(grep -m1 -E '^#+[[:space:]]+' "$body" 2>/dev/null | sed -E 's/^#+[[:space:]]+//')"
topic="$(sj_slugify "$topic" 50)"
[ -n "$topic" ] || topic="note"

[ -n "$project" ] || project="$(sj_project_key "$PWD")"
[ -n "$project" ] || die "cannot determine the project key for $PWD"

# Session backlink, best-effort: ask the harness adapter for the transcript of the session running
# in this cwd right now. Absent (no harness, no session, backfill) the note simply carries no id.
sid8=""
if sid_path="$(sj_adapter_call "$(sj_harness)" sjh_find_live_transcript "$PWD" 2>/dev/null)" \
   && [ -n "$sid_path" ]; then
  sid="$(basename "$sid_path")"; sid="${sid%.*}"
  [ -n "$sid" ] && sid8="__$(sj_session_handle "$sid")"
fi

dir="$MEM/$project/notes"
mkdir -p "$dir" || die "cannot create $dir"
target="$(sj_unique_path "$dir" "$(date +%F)_${topic}${sid8}" md)"
cp -- "$body" "$target" || die "cannot write $target"

# ---- index -----------------------------------------------------------------------------------
# ONE line in MEMORY.md, rewritten in place, never one line per note. MEMORY.md is auto-loaded into
# every session and budgeted (200 lines / 25KB), so an index that grows with the corpus would spend
# exactly the context that keeping notes out of memory was meant to save. This line is a constant-
# size pointer at the mechanism: it tells a fresh session that notes exist and how to reach them.
index="$MEM/$project/MEMORY.md"
n=0; for f in "$dir"/*.md; do [ -f "$f" ] && n=$((n + 1)); done
plural="s"; [ "$n" = 1 ] && plural=""
line="- notes/ — $n document$plural, not auto-loaded; retrieve with /sjrecall or /sjbrowse note"
tmp="$(mktemp)" || die "cannot create a temp file"
if [ -f "$index" ]; then grep -v '^- notes/ ' "$index" > "$tmp"; else printf '# Memory index\n\n' > "$tmp"; fi
printf '%s\n' "$line" >> "$tmp"
mv -- "$tmp" "$index" 2>/dev/null || rm -f "$tmp"

printf '\033[1;32m✓\033[0m note written: %s\n' "$(sj_pretty_path "$target")"

# ---- publish ---------------------------------------------------------------------------------
# Push NOW rather than waiting for SessionEnd. The point of a note is that it is durable the moment
# it is written; a note that only reaches the NAS when the session happens to end cleanly reproduces
# the scratchpad problem it exists to fix. memory-sync.sh is best-effort and always exits 0, so an
# unreachable remote leaves the note committed locally to be pushed by the next sync.
if [ "$push" = 1 ]; then
  remote="$(sj_memory_remote)"
  if [ -n "$remote" ]; then
    bash "$APP/bin/memory-sync.sh" push >/dev/null 2>&1
    printf '  published to %s\n' "$remote"
  else
    printf '  (memory sync is off on this host — the note is local until /sjmemory is run)\n'
  fi
fi
exit 0
