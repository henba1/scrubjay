#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# Catalogue + archive the sessions that ended without ever reaching the session-end hook.
#
# Why this exists: everything that records a session — the catalogue row, the transcript relay, the
# readable rendering — hangs off ONE event, hooks/log-session.sh firing at session end. A `kill -9`,
# a closed terminal, a dropped SSH connection or a power cut skips it, and then nothing records the
# session and nothing reports that: the relay breadcrumb is written by the ship that never ran, so
# the next SessionStart has nothing to warn about, and sj-doctor.sh checks wiring rather than
# stranded content. The failure mode is an absence, and absences are what this system cannot notice.
#
# So: derive the record from the transcript instead of from being alive when the session ends.
# Everything a row needs is in the file. (The one thing a later pass cannot recover is /sjlog's
# model-authored essence — the row falls back to the first user prompt, as the automatic path does.)
#
#   usage: sj-reconcile.sh [--all] [--dry-run] [--quiet-mins N] [--within-days N] [--max N]
#                          [--exclude SID]
#
#     --all            no age limits: every uncatalogued session on this machine, however old.
#                      This is the back-catalogue sweep — pair it with bin/backfill-transcripts.sh.
#     --dry-run        print what would be reconciled; write, ship and push nothing. sj-doctor.sh
#                      uses this, which is what keeps that tool read-only.
#     --quiet-mins N   only sessions untouched for N minutes (default 30). See "liveness" below.
#     --within-days N  only sessions modified in the last N days (default 14).
#     --max N          reconcile at most N sessions per run (default 25); the rest wait for the
#                      next run. --all lifts the cap. Keeps one SessionStart bounded.
#     --exclude SID    never touch this session (the caller's own, from the SessionStart payload).
#
# Exit 0 always — it is called from a hook and must never block a session.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 0
. "$APP/bin/lib.sh"; sj_load_config

ALL=0; DRY=0; QUIET_MINS=30; WITHIN_DAYS=14; MAX=25; EXCLUDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all)          ALL=1 ;;
    --dry-run|-n)   DRY=1 ;;
    --quiet-mins)   QUIET_MINS="${2:?--quiet-mins needs a number}"; shift ;;
    --within-days)  WITHIN_DAYS="${2:?--within-days needs a number}"; shift ;;
    --max)          MAX="${2:?--max needs a number}"; shift ;;
    --exclude)      EXCLUDE="${2:?--exclude needs a session id}"; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'sj-reconcile: unknown argument %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
case "$QUIET_MINS$WITHIN_DAYS$MAX" in
  *[!0-9]*) echo "sj-reconcile: --quiet-mins/--within-days/--max take integers" >&2; exit 2 ;;
esac

harness="$(sj_harness)"
sj_load_adapter "$harness" || exit 0
declare -F sjh_list_sessions >/dev/null 2>&1 || exit 0   # adapter predates the contract

host="$(sj_host)"
DATA="$(sj_data 2>/dev/null || true)"
[ -n "$DATA" ] && [ -d "$DATA" ] || exit 0
LOG="$DATA/logs/$host.log"; mkdir -p "$DATA/logs" 2>/dev/null; touch "$LOG" 2>/dev/null

now="$(date +%s)"
quiet_before=$(( now - QUIET_MINS * 60 ))
within_after=$(( now - WITHIN_DAYS * 86400 ))

# ---- select ------------------------------------------------------------------------------------
# Cheapest filter first, so the common case (nothing to do) costs a find and a stat per file and
# reads no transcript at all. Only a genuine orphan pays for the jq passes in sj_log_row.
#
# LIVENESS is the one judgement call: a transcript that exists is not proof its session ended. A
# live session in another terminal is still writing, so "untouched for --quiet-mins" separates
# crashed from running. It does not have to be right, and that is by design: if this reconciles a
# session that is actually alive — resumed with `claude --resume`, so its transcript is old and
# quiet — then when that session ends properly, sj_log_row's write-once guard keeps the row single
# and the ship simply overwrites the archive with the fuller transcript. The residue is a row whose
# turns=/size= are stale, which is precisely what a repeated /sjlog already leaves. A false positive
# costs nothing the system does not already do.
candidates=(); n_cand=0
while IFS=$'\t' read -r sid tpath; do
  [ -n "$sid" ] && [ -n "$tpath" ] || continue
  [ "$sid" = "$EXCLUDE" ] && continue
  [ -s "$tpath" ] || continue                          # recorded nothing -> nothing to catalogue
  mt="$(sj_mtime "$tpath")" || continue                # cannot ask -> do not guess
  if [ "$ALL" != 1 ]; then
    [ "$mt" -le "$quiet_before" ] || continue          # still being written -> probably alive
    [ "$mt" -ge "$within_after" ] || continue          # back catalogue -> --all territory
  fi
  grep -q "session=$sid" "$LOG" 2>/dev/null && continue   # already catalogued
  candidates+=("$sid"$'\t'"$tpath"$'\t'"$mt"); n_cand=$((n_cand+1))
done < <(sjh_list_sessions)

# Count as we go rather than asking for ${#candidates[@]}: expanding an EMPTY array under `set -u`
# is an error on bash 3.2 (macOS) and 4.2/4.3, and this runs inside a hook where that death is
# silent. Below this guard the array is known non-empty, so ${#…} is safe again.
if [ "$n_cand" -eq 0 ]; then
  [ "$DRY" = 1 ] && echo "sj-reconcile: nothing stranded (harness=$harness, host=$host)"
  exit 0
fi

# Oldest first, so the rows land in the log in the order the sessions actually happened. Read into
# an array the long way rather than with `mapfile`, which is bash 4+ and this runs on the
# SessionStart path — macOS still ships bash 3.2.
sorted=()
while IFS= read -r line; do [ -n "$line" ] && sorted+=("$line"); done \
  < <(printf '%s\n' "${candidates[@]}" | sort -t$'\t' -k3 -n)
candidates=("${sorted[@]}")

total="${#candidates[@]}"

# Only one writer at a time. Two sessions starting together — two terminals, or a script — would
# otherwise both find the same orphan, both pass the grep, and both append a row; and then both
# commit and push the data repo at once, which is the failure class the push fallback in
# sj_data_push exists to clean up after. `mkdir` is the atomic test-and-set every POSIX filesystem
# agrees on. A lock left behind by a killed run is taken over after an hour rather than blocking
# the sweep forever — the irony of a crash disabling crash recovery is not lost.
# --dry-run takes no lock: it writes nothing, and sj-doctor.sh must not go quiet during a sweep.
if [ "$DRY" != 1 ]; then
  lock="${TMPDIR:-/tmp}/scrubjay-reconcile.$(id -u).lock"
  if ! mkdir "$lock" 2>/dev/null; then
    lmt="$(sj_mtime "$lock" 2>/dev/null)" || lmt=0
    if [ "$(( now - lmt ))" -gt 3600 ]; then
      rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || exit 0
    else
      # stderr, not stdout: a hook discards it, an interactive `--all` sees why nothing happened.
      echo "sj-reconcile: another run holds the lock — leaving this sweep to it" >&2
      exit 0
    fi
  fi
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT INT TERM
fi

if [ "$DRY" = 1 ]; then
  # The full count, uncapped — sj-doctor.sh reports this number, and a cap applied before counting
  # would tell someone with 60 stranded sessions that they have 25.
  printf 'sj-reconcile: %d session(s) not in the catalogue (harness=%s, host=%s)\n' \
    "$total" "$harness" "$host"
  n=0
  while IFS=$'\t' read -r sid tpath mt; do
    n=$((n+1))
    if [ "$n" -gt 20 ]; then printf '  … and %d more\n' "$((total - 20))"; break; fi
    printf '  %s  %s  %s\n' "$(sj_epoch_stamp "$mt")" "$(sj_session_handle "$sid")" \
      "$(sj_pretty_path "$tpath")"
  done < <(printf '%s\n' "${candidates[@]}")
  exit 0
fi

# Bound the work one invocation may do. Reconciling ships transcripts, and SessionStart hooks are
# awaited — a machine that has accumulated a fortnight of orphans must not turn the next session's
# startup into a bulk upload. The remainder is picked up by the following session, and `--all`
# (run by hand) is the way to clear a real backlog in one go.
deferred=0
if [ "$ALL" != 1 ] && [ "$total" -gt "$MAX" ]; then
  deferred=$(( total - MAX ))
  candidates=("${candidates[@]:0:$MAX}")
fi

# ---- record ------------------------------------------------------------------------------------
rows=0; shipped=0
while IFS=$'\t' read -r sid tpath mt; do
  cwd="$(sjh_session_cwd "$tpath" 2>/dev/null)"
  # The row is dated when the session DIED (the transcript's mtime), not when it was recovered.
  # A week-old crash surfacing in the catalogue as today's work would be worse than missing: the
  # catalogue is sorted by that timestamp, and /sjbrowse's "what was I doing" answer depends on it.
  if sj_log_row "$LOG" "$sid" "$cwd" "$tpath" "$harness" "$host" "$(sj_epoch_stamp "$mt")" ""; then
    rows=$((rows+1))
  fi
  if [ "${SCRUBJAY_NOSHIP:-0}" != "1" ]; then
    slug="$(sjh_session_slug "$tpath" "$cwd" 2>/dev/null)"
    if [ -n "$slug" ] && SCRUBJAY_HARNESS="$harness" \
         "$APP/bin/ship-transcript.sh" "$tpath" "$slug" "$sid" "$host" "$cwd" >/dev/null 2>&1; then
      shipped=$((shipped+1))
    fi
  fi
done < <(printf '%s\n' "${candidates[@]}")

# ---- publish -----------------------------------------------------------------------------------
# ONE commit and ONE catalogue render for the whole batch, not per session — and only if a row was
# actually written, so a pass that found nothing new never touches git.
if [ "$rows" -gt 0 ]; then
  [ "$harness" = claude ] && "$APP/bin/claude-index-chats.sh" >/dev/null 2>&1 || true
  sj_data_push "auto-sync (reconcile): $host recovered $rows session(s)"
  "$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1 || true
fi

# Say it out loud. When run from SessionStart this lands in the session's context, which is how the
# relay-failure and pending-authorization notices already reach the user — turning the absence that
# started all this into a message.
if [ "$rows" -gt 0 ]; then
  printf 'scrubjay: recovered %d session(s) that ended without a clean exit — catalogued%s.%s\n' \
    "$rows" "$([ "$shipped" -gt 0 ] && printf ' and archived')" \
    "$([ "$deferred" -gt 0 ] && printf ' %d more are still stranded and will be picked up next session (or run bin/sj-reconcile.sh --all).' "$deferred")"
fi
exit 0
