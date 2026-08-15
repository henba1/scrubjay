#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# bin/sj-reconcile.sh — the pass that catalogues + archives sessions which ended without the
# session-end hook ever firing (kill -9, closed terminal, power cut).
#
# Two things make this worth testing rather than eyeballing. First, it WRITES to the catalogue and
# ships to the archive from a hook that runs at the start of every session, so a selection bug is a
# bug that fires constantly. Second, its liveness rule is a heuristic — "untouched for N minutes" —
# and the tests below pin both directions of it: a quiet session is recovered, a live one is left
# alone, and neither answer depends on when the test happens to run (every age is set with an
# explicit `touch -t` and selected with an explicit window, never with clock arithmetic).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

LOG="$SCRUBJAY_DATA/logs/testhost.log"
proj="$HOME/.claude/projects/-home-user-widget-api"; mkdir -p "$proj"
RECON="$APP/bin/sj-reconcile.sh"

# A stranded session is just a transcript nobody catalogued. `touch -t` is POSIX (GNU's -d is not),
# and an absolute stamp keeps every assertion below independent of the wall clock.
OLD_STAMP=202607141200; OLD_ROW="2026-07-14 12:00"
plant() {  # plant <sid> [mtime-stamp]
  cp "$FIXTURES/claude-session.jsonl" "$proj/$1.jsonl"
  [ -n "${2:-}" ] && touch -t "$2" "$proj/$1.jsonl"
  printf '%s' "$proj/$1.jsonl"
}
# A window wide enough that only the explicit `touch -t` ages matter, never today's date.
WIDE="--within-days 36500"

sid_a="aaaaaaaa-2222-4333-8444-555555555555"; plant "$sid_a" "$OLD_STAMP" >/dev/null

section "it runs as a program"
# Both callers — hooks/sync-session.sh and sj-doctor.sh — exec the path directly rather than
# `bash <path>`. Without the exec bit that fails silently: doctor reported "could not enumerate
# sessions" and looked healthy while the sweep never ran at all.
check "sj-reconcile.sh is executable" test -x "$RECON"
check "and answers when invoked directly" "$RECON" --dry-run

section "a session that never reached the hook is catalogued and archived"
out="$(SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE 2>&1)"
assert_contains "it says what it recovered" "$out" "recovered 1 session"
row="$(grep "session=$sid_a" "$LOG")"
assert_contains "the row carries the harness" "$row" "| harness=claude |"
assert_contains "and the topic, read from the transcript" "$row" \
  '"the retry backoff fires twice per failure — find out why"'
assert_contains "and the cwd recorded inside it" "$row" "| /home/user/widget-api |"
assert_file "the transcript reached the archive" \
  "$SCRUBJAY_LOCAL_CHATS/testhost/-home-user-widget-api/$sid_a.jsonl"

section "the row is dated when the session DIED, not when it was recovered"
# Otherwise a week-old crash sorts into the catalogue as today's work — worse than missing, because
# /sjbrowse orders by exactly this field.
assert_eq "row timestamp comes from the transcript's mtime" "$OLD_ROW" "${row:0:16}"

section "running again changes nothing (idempotent)"
n_before="$(grep -c "session=$sid_a" "$LOG")"
out2="$(SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE 2>&1)"
assert_eq "no second row for the same session" "$n_before" "$(grep -c "session=$sid_a" "$LOG")"
assert_eq "and it reports nothing recovered" "" "$out2"

section "a session that is still being written is left alone"
# The liveness rule: a live session in another terminal has a transcript too. Its mtime is now, so
# the default 30-minute quiet period must exclude it.
sid_live="bbbbbbbb-2222-4333-8444-555555555555"; plant "$sid_live" >/dev/null
SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE >/dev/null 2>&1
assert_eq "no row for a transcript touched just now" "0" "$(grep -c "session=$sid_live" "$LOG")"
# …and it IS picked up once it goes quiet, so the exclusion is about age and nothing else.
SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE --quiet-mins 0 >/dev/null 2>&1
assert_eq "but it is picked up once quiet" "1" "$(grep -c "session=$sid_live" "$LOG")"

section "the session invoking the pass is never reconciled by it"
sid_self="cccccccc-2222-4333-8444-555555555555"; plant "$sid_self" "$OLD_STAMP" >/dev/null
SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE --exclude "$sid_self" >/dev/null 2>&1
assert_eq "--exclude keeps the caller's own session out" "0" "$(grep -c "session=$sid_self" "$LOG")"

section "a session that recorded nothing gets no row"
# Same contract sj_log_row enforces for the hook: no transcript means nothing was archived, so a
# row would point at an archive entry that does not exist.
sid_empty="dddddddd-2222-4333-8444-555555555555"; : > "$proj/$sid_empty.jsonl"
touch -t "$OLD_STAMP" "$proj/$sid_empty.jsonl"
SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE >/dev/null 2>&1
assert_eq "no row for a zero-byte transcript" "0" "$(grep -c "session=$sid_empty" "$LOG")"

section "the age window: old sessions wait for --all"
sid_old="eeeeeeee-2222-4333-8444-555555555555"; plant "$sid_old" "$OLD_STAMP" >/dev/null
SCRUBJAY_HARNESS=claude bash "$RECON" >/dev/null 2>&1          # default --within-days 14
assert_eq "outside the window, the automatic pass ignores it" "0" "$(grep -c "session=$sid_old" "$LOG")"
SCRUBJAY_HARNESS=claude bash "$RECON" --all >/dev/null 2>&1
assert_eq "--all sweeps the back catalogue" "1" "$(grep -c "session=$sid_old" "$LOG")"

section "--dry-run reports without writing anything"
sid_dry="ffffffff-2222-4333-8444-555555555555"; plant "$sid_dry" "$OLD_STAMP" >/dev/null
dry="$(SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE --dry-run 2>&1)"
assert_contains "it names the count" "$dry" "1 session(s) not in the catalogue"
assert_contains "and lists the session by its handle" "$dry" "ffffffff"
assert_eq "but wrote no row" "0" "$(grep -c "session=$sid_dry" "$LOG")"
assert_eq "and shipped nothing" "0" \
  "$(ls "$SCRUBJAY_LOCAL_CHATS/testhost/-home-user-widget-api/$sid_dry.jsonl" 2>/dev/null | wc -l)"

section "one run is bounded; the rest wait for the next"
for i in 1 2 3; do plant "1111111$i-2222-4333-8444-555555555555" "$OLD_STAMP" >/dev/null; done
out3="$(SCRUBJAY_HARNESS=claude bash "$RECON" $WIDE --max 2 2>&1)"
assert_contains "it caps the batch and says so" "$out3" "still stranded"
# 4 were pending here (the three above + the --dry-run one), so exactly 2 land and 2 remain.
assert_eq "exactly --max rows were written" "2" \
  "$(grep -c 'session=1111111[123]-\|session=ffffffff' "$LOG")"

section "subagent transcripts are not sessions"
# projects/<slug>/<sid>/agent-*.jsonl are artifacts of a parent session. Catalogueing one would
# invent a session the user can neither resume nor recognize.
mkdir -p "$proj/$sid_a"
cp "$FIXTURES/claude-session.jsonl" "$proj/$sid_a/agent-worker.jsonl"
touch -t "$OLD_STAMP" "$proj/$sid_a/agent-worker.jsonl"
listed="$(SCRUBJAY_HARNESS=claude bash -c '. "$0/bin/lib.sh"; sj_load_adapter claude; sjh_list_sessions' "$APP")"
assert_eq "the nested transcript is not listed as a session" "0" \
  "$(printf '%s\n' "$listed" | grep -c 'agent-worker')"

section "opencode has nothing to reconcile, by design"
# It publishes on session.idle — after every turn — so a crashed opencode session is already
# catalogued. Empty output here is the correct answer, not a missing implementation.
oc="$(bash -c '. "$0/bin/lib.sh"; sj_load_adapter opencode; sjh_list_sessions' "$APP")"
assert_eq "sjh_list_sessions is empty for opencode" "" "$oc"

section "bad input fails loudly rather than doing the wrong thing"
check_fails "a non-numeric window is refused" bash "$RECON" --within-days soon
check_fails "an unknown argument is refused" bash "$RECON" --sweep-everything

finish
