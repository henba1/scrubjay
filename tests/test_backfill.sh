#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# bin/backfill-transcripts.sh — the one-shot that ships a machine's pre-scrubjay history.
#
# Worth pinning because the script's failure mode is silent and asymmetric: shipping without
# cataloguing leaves an archive full of transcripts that /sjbrowse, /sjtable and /sjrecall cannot
# see, and the user's only signal is content they never look for. The checks below cover both
# halves, and the fields that only exist when the index pass goes through an adapter — a row whose
# cwd is the directory slug instead of the session's real cwd renders as "-home-user-widget-api"
# everywhere the catalogue is read.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

BACKFILL="$APP/bin/backfill-transcripts.sh"
LOG="$SCRUBJAY_DATA/logs/testhost.log"
proj="$CLAUDE_CONFIG_DIR/projects/-home-user-widget-api"; mkdir -p "$proj"

# An absolute `touch -t` stamp (POSIX; GNU's -d is not), so no assertion depends on the wall clock.
OLD_STAMP=202607141200; OLD_ROW="2026-07-14 12:00"
plant() {  # plant <sid> [mtime-stamp]
  cp "$FIXTURES/claude-session.jsonl" "$proj/$1.jsonl"
  [ -n "${2:-}" ] && touch -t "$2" "$proj/$1.jsonl"
  printf '%s' "$proj/$1.jsonl"
}

sid_a="aaaaaaaa-2222-4333-8444-555555555555"; plant "$sid_a" "$OLD_STAMP" >/dev/null
sid_b="bbbbbbbb-2222-4333-8444-555555555555"; plant "$sid_b" "$OLD_STAMP" >/dev/null

section "it ships the back catalogue and catalogues it in one pass"
out="$(bash "$BACKFILL" 2>&1)"
assert_contains "it reports what it found" "$out" "found 2 transcripts"
assert_file "the transcript reached the archive" \
  "$SCRUBJAY_LOCAL_CHATS/testhost/-home-user-widget-api/$sid_a.jsonl"
assert_contains "and it says what it catalogued" "$out" "recovered 2 session"

section "the row carries what only an adapter can supply"
# The whole point of delegating to sj-reconcile.sh: an index pass with no adapter loaded writes the
# directory slug as the cwd and leaves model/turns empty, and every reader of the catalogue
# (sj-catalogue.sh, sjmcp, sj-resume.sh) takes the basename of that field as the project name.
row="$(grep "session=$sid_a" "$LOG")"
assert_contains "the cwd recorded inside the transcript, not the slug" "$row" "| /home/user/widget-api |"
assert_contains "the model the session answered on" "$row" "| model=claude-opus-4-8 |"
assert_contains "the turn count" "$row" "| turns=5 |"
assert_contains "the harness, whatever the ambient env says" "$row" "| harness=claude |"
assert_contains "and the topic, read from the transcript" "$row" \
  '"the retry backoff fires twice per failure — find out why"'

section "the row is dated when the session happened"
assert_eq "timestamp comes from the transcript's mtime" "$OLD_ROW" "${row:0:16}"

section "a live session is not catalogued mid-flight"
# --quiet-mins is why this script must not use --all. Backfill is run by hand from inside a session
# whose transcript is still being written; a row written now would freeze that session's turns= and
# size= at a partial count, and sj_log_row's write-once guard means the real SessionEnd row would
# never replace it.
sid_live="cccccccc-2222-4333-8444-555555555555"; plant "$sid_live" >/dev/null
bash "$BACKFILL" >/dev/null 2>&1
assert_file "the live session is still shipped" \
  "$SCRUBJAY_LOCAL_CHATS/testhost/-home-user-widget-api/$sid_live.jsonl"
check "but it gets no catalogue row yet" \
  bash -c '! grep -q "session=$1" "$2"' _ "$sid_live" "$LOG"

section "running again writes no second row (idempotent)"
before="$(grep -c "session=$sid_a" "$LOG")"
bash "$BACKFILL" >/dev/null 2>&1
assert_eq "no duplicate row for a session already catalogued" \
  "$before" "$(grep -c "session=$sid_a" "$LOG")"

section "it survives a harness set in the environment"
# The script only ever walks the Claude projects dir, so a SCRUBJAY_HARNESS left over from an
# opencode or codex bridge must not relabel these rows — the label picks the adapter that later
# renders and resumes them.
sid_d="dddddddd-2222-4333-8444-555555555555"; plant "$sid_d" "$OLD_STAMP" >/dev/null
SCRUBJAY_HARNESS=opencode bash "$BACKFILL" >/dev/null 2>&1
assert_contains "row is still harness=claude" "$(grep "session=$sid_d" "$LOG")" "| harness=claude |"

finish
