#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Give the catalogue's topic-less sessions a topic, by reading the transcripts they left behind.
#
#   sj-topics.sh                    this host's rows, newest first
#   sj-topics.sh --dry-run          say what it would write, write nothing
#   sj-topics.sh --limit 50         stop after 50 rows (default 200)
#   sj-topics.sh --all-hosts        every host's rows, not just this machine's
#   sj-topics.sh --host laptop      one named host's rows
#
# ── why this exists ───────────────────────────────────────────────────────────────────────────
# The one-sentence topic is the only handle a session has that a human can search by, and the only
# thing /sjrecall can rank a *log-only* session on. It is authored in two places: by the model on
# the /sjlog path, and by hooks/log-session.sh at session end, which reads the transcript's first
# real prompt. Neither runs retroactively, so every session that ended before the fallback could
# read its transcript is in the catalogue as `(no text)` — findable only if you already know its id.
#
# ── why it APPENDS instead of editing the row it is fixing ────────────────────────────────────
# logs/*.log ride the data repo with `merge=union` (.gitattributes). That works — silently, with no
# conflicts, across any number of machines — for exactly one reason: every host only ever *appends*
# to its own file, so union of both sides is always the right answer. Rewriting a line in place
# forfeits that: union would keep the old line AND the new one anyway, and any genuinely diverged
# hunk becomes a rebase conflict in the middle of a SessionEnd hook, which is the wedge class
# log-session.sh goes to great lengths to avoid.
#
# So a backfilled topic is a *new row for the same session id*, byte-identical to the original
# except for the topic field, appended like any other. Every reader resolves duplicate ids
# last-wins — sj_log_catalogue, bin/sj-catalogue.sh, sjmcp's _iter_logs — so the corrected row is
# the one that shows. Union of two hosts that both backfilled the same session is still just two
# rows with a topic, and last-wins picks one; there is no state to conflict over.
#
# By default only THIS host's rows are touched, which keeps the append-only-to-your-own-file
# property intact. --all-hosts is for the archive box, which is usually the only machine that can
# read every host's transcripts anyway.
#
# ── what it cannot fix ────────────────────────────────────────────────────────────────────────
# A row whose transcript never reached this archive, and a session that recorded nothing at all
# (`size=0` — SessionEnd fired for a session with no turns; hooks/log-session.sh no longer writes
# a row for those, but the historical ones remain). Both are reported as skipped, not as failures:
# there is no text to read, so there is no topic to author.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh"; sj_load_config

dry=0; limit=200; only_host=""; render=1
me="$(sj_host)"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   dry=1 ;;
    --all-hosts) only_host="*" ;;
    --host)      shift; only_host="${1:-}" ;;
    --limit)     shift; limit="${1:-200}" ;;
    --no-render) render=0 ;;
    -h|--help)   awk 'NR>3 && /^#/ {sub(/^# ?/,""); print; next} NR>3{exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'sj-topics: unknown argument %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$only_host" ] || only_host="$me"
case "$limit" in ''|*[!0-9]*) printf 'sj-topics: --limit needs a number\n' >&2; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { printf 'sj-topics: jq is required\n' >&2; exit 1; }
DATA="$(sj_data)" || exit 1
[ -d "$DATA/logs" ] || { printf 'sj-topics: no logs at %s/logs\n' "$DATA" >&2; exit 1; }

# ── the transport's read side ─────────────────────────────────────────────────────────────────
# Same seam bin/sj-resume.sh uses, so this works on every backend: `local`/`git` resolve on the
# filesystem, `rsync-wg` over the sjmcp SSH channel (its relay key is write-only by design).
backend="${SCRUBJAY_TRANSCRIPT_BACKEND:-git}"
impl="$APP/hooks/transports/$backend.sh"
[ -f "$impl" ] || { printf 'sj-topics: unknown backend %s\n' "$backend" >&2; exit 1; }
# shellcheck source=/dev/null  # backend chosen at runtime; see hooks/transports/<backend>.sh
. "$impl"
command -v transport_resolve >/dev/null 2>&1 || {
  printf "sj-topics: backend '%s' has no read side — nothing to backfill from\n" "$backend" >&2; exit 1; }

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

# ── which rows still need a topic ─────────────────────────────────────────────────────────────
# Last row per session id wins (a previous run may already have appended one), and only the
# survivors that are still topic-less are candidates. Emits TSV: <host> <sid> <line>, newest first.
#
# Four literal [0-9] rather than [0-9]{4}: mawk has no interval expressions and would match
# nothing here, silently. See AGENTS.md and tests/test_portability.sh.
awk -F' *\\| *' -v OFS='\t' -v want="$only_host" '
  /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
    sid = ""
    for (i = 5; i <= NF; i++) if ($i ~ /^session=/) { sid = substr($i, 9); break }
    if (sid == "") next
    topic = $4; gsub(/^"|"$/, "", topic)
    if (topic == "(no text)") topic = ""
    host[sid] = $2; line[sid] = $0; ts[sid] = $1; has[sid] = (topic != "")
  }
  END {
    for (s in line) {
      if (has[s]) continue
      if (want != "*" && host[s] != want) continue
      print ts[s], host[s], s, line[s]
    }
  }
' "$DATA"/logs/*.log 2>/dev/null | sort -r | cut -f2- > "$tmp/todo"

todo="$(wc -l < "$tmp/todo" | tr -d ' ')"
if [ "$todo" -eq 0 ]; then
  printf 'sj-topics: every %s row already has a topic — nothing to do\n' \
    "$([ "$only_host" = "*" ] && echo "catalogue" || echo "$only_host")"
  exit 0
fi
printf 'sj-topics: %s topic-less row(s) for %s; reading up to %s from the archive (backend: %s)\n' \
  "$todo" "$([ "$only_host" = "*" ] && echo "every host" || echo "$only_host")" "$limit" "$backend"

# ── author one topic per row ──────────────────────────────────────────────────────────────────
fixed=0; noarchive=0; notext=0; seen=0
while IFS=$'\t' read -r host sid line; do
  [ "$seen" -lt "$limit" ] || break
  seen=$((seen + 1))

  # An id must be long enough to identify one session before it is worth resolving. The archive
  # matches a handle ANYWHERE in a filename (sj_archive_resolve), so a short one is a wildcard: a
  # real row in the wild reads `session=t`, and resolving that matched an arbitrary transcript and
  # would have stamped a completely unrelated session's prompt onto it. 8 is the handle length the
  # rest of scrubjay commits to (sj_session_handle) — below it, treat the row as unresolvable.
  if [ "${#sid}" -lt 8 ]; then noarchive=$((noarchive + 1)); continue; fi

  # The same id legitimately exists under several hosts once a session has been handed off, and a
  # hand-off only ever appends turns — so the longest copy is the fullest record of the session.
  cands="$(transport_resolve "$sid" 2>/dev/null)"
  if [ -z "$cands" ]; then noarchive=$((noarchive + 1)); continue; fi

  # …but only when every candidate IS that one session. A handle can match two different sessions,
  # and writing the wrong session's prompt into a row is worse than leaving the row blank: it reads
  # as authored, so nothing about it invites a second look. Ambiguity is a skip, never a guess.
  if [ "$(printf '%s\n' "$cands" | cut -f1 | sed 's#.*/##; s#\.[^.]*$##' | sort -u | wc -l)" -gt 1 ]; then
    noarchive=$((noarchive + 1)); continue
  fi
  relpath="$(printf '%s\n' "$cands" | sort -k2,2nr -k3,3nr | head -1 | cut -f1)"
  [ -n "$relpath" ] || { noarchive=$((noarchive + 1)); continue; }

  # The archived name carries the format (.jsonl / .json); nothing in the path says which harness
  # wrote it, so ask the records themselves and let that adapter read the topic.
  ext="${relpath##*.}"; [ "$ext" != "$relpath" ] || ext="jsonl"
  raw="$tmp/session.$ext"; rm -f "$tmp"/session.* 2>/dev/null
  transport_fetch "$relpath" "$raw" >/dev/null 2>&1 || { noarchive=$((noarchive + 1)); continue; }
  [ -s "$raw" ] || { noarchive=$((noarchive + 1)); continue; }

  h="$(sj_detect_harness "$raw" 2>/dev/null)" || h=""
  if [ -n "$h" ]; then topic="$(sj_adapter_call "$h" sjh_session_topic "$raw" 2>/dev/null)"
  else                 topic="$(sj_session_topic "$raw")"; fi
  topic="$(sj_topic_sanitize "${topic:-}")"
  if [ -z "$topic" ]; then notext=$((notext + 1)); continue; fi

  new="$(sj_log_retopic "$line" "$topic")" || { notext=$((notext + 1)); continue; }
  if [ "$dry" = 1 ]; then
    printf '  would set %.8s -> %s\n' "$sid" "$topic"
  else
    printf '%s\n' "$new" >> "$DATA/logs/$host.log" || continue
    printf '  %.8s -> %s\n' "$sid" "$topic"
  fi
  fixed=$((fixed + 1))
done < "$tmp/todo"

printf '\nsj-topics: %s %s topic(s), %s not resolvable in this archive, %s with no readable prompt (%s row(s) examined)\n' \
  "$([ "$dry" = 1 ] && echo "would author" || echo "authored")" \
  "$fixed" "$noarchive" "$notext" "$seen"
[ "$seen" -lt "$todo" ] && printf 'sj-topics: %s row(s) left — re-run to continue.\n' "$((todo - seen))"

# The rendered table is derived from the logs we just appended to, so refresh it rather than leave
# a stale copy that disagrees with what /sjbrowse now reports. --no-pull: this pass is about rows
# already here, and a network hop would make a dry run non-obviously slow.
if [ "$dry" = 0 ] && [ "$fixed" -gt 0 ] && [ "$render" = 1 ]; then
  "$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1 || true
fi
exit 0
