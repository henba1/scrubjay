#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The session-log line hooks/log-session.sh appends is the whole catalogue — it is what /sjbrowse
# and /sjrecall read, and what rides the data repo to every machine. This proves the enriched line
# (topic + harness + model + turns + size), the model-authored-topic override, and the write-once
# dedupe. The reader half (sjmcp's _LOG regex) is exercised by the manual parser check; here we lock
# the *shape* the reader depends on.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
export SCRUBJAY_NOSHIP=1   # this test is about the log line, not the transcript relay

LOG="$SCRUBJAY_DATA/logs/testhost.log"

# A claude session on disk where the harness expects it, so the hook detects it and reads its meta.
proj="$HOME/.claude/projects/-home-user-widget-api"; mkdir -p "$proj"
sid="11111111-2222-4333-8444-555555555555"
cp "$FIXTURES/claude-session.jsonl" "$proj/$sid.jsonl"
size="$(stat -c%s "$proj/$sid.jsonl")"
payload() { printf '{"session_id":"%s","cwd":"/home/user/widget-api","transcript_path":"%s"}' "$1" "$proj/$1.jsonl"; }

section "automatic SessionEnd: enriched line, first-prompt topic"
SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(payload "$sid")"
line="$(grep "session=$sid" "$LOG")"
assert_contains "topic falls back to the first real prompt" "$line" \
  '"the retry backoff fires twice per failure — find out why"'
assert_contains "carries harness + model" "$line" "| harness=claude | model=claude-opus-4-8 |"
assert_contains "carries the turn count" "$line" "| turns=5 |"
assert_contains "carries the byte size" "$line" "| size=$size"

section "publish (/sjlog): a model-authored essence overrides the first prompt"
sid2="22222222-2222-4333-8444-555555555555"; cp "$FIXTURES/claude-session.jsonl" "$proj/$sid2.jsonl"
SCRUBJAY_HARNESS=claude SCRUBJAY_TOPIC="Fixed double-wrapped retry in the HTTP client" \
  bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' "$APP" "$(payload "$sid2")"
line2="$(grep "session=$sid2" "$LOG")"
assert_contains "essence topic wins over the first prompt" "$line2" \
  '"Fixed double-wrapped retry in the HTTP client"'
assert_contains "essence line still carries model" "$line2" "| model=claude-opus-4-8 |"

section "a stray pipe or quote in the topic cannot break the line"
sid3="33333333-2222-4333-8444-555555555555"; cp "$FIXTURES/claude-session.jsonl" "$proj/$sid3.jsonl"
SCRUBJAY_HARNESS=claude SCRUBJAY_TOPIC='weird | topic "with" pipes' \
  bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' "$APP" "$(payload "$sid3")"
line3="$(grep "session=$sid3" "$LOG")"
# the topic field must contain exactly one opening + closing quote pair and no bare pipe inside it
assert_contains "quotes are stripped, pipe neutralized" "$line3" '"weird / topic with pipes"'
assert_contains "trailing fields survive the sanitize" "$line3" "| harness=claude | model="

section "a session that recorded nothing gets no catalogue row"
# SessionEnd fires for a session that ended without a single user turn (open, /clear or quit
# straight away) and names a transcript_path the harness never wrote. Nothing is shipped for it,
# so a row would advertise an archive entry that does not exist.
sid4="44444444-2222-4333-8444-555555555555"   # named, never written
SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(payload "$sid4")"
assert_eq "no row for a transcript that was never written" "0" "$(grep -c "session=$sid4" "$LOG")"

sid5="55555555-2222-4333-8444-555555555555"; : > "$proj/$sid5.jsonl"   # written, zero bytes
SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(payload "$sid5")"
assert_eq "no row for an empty transcript" "0" "$(grep -c "session=$sid5" "$LOG")"

section "write-once: re-ending the same session adds no second line"
n_before="$(grep -c "session=$sid" "$LOG")"
SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(payload "$sid")"
assert_eq "still one line for the session" "$n_before" "$(grep -c "session=$sid" "$LOG")"

section "per turn (Stop): the first turn writes the row, later turns leave it be"
# Stop fires at the end of every turn; the session must be catalogued (and relayed) from the first.
export SCRUBJAY_TURN_SETTLE=0
sid6="66666666-2222-4333-8444-555555555555"; cp "$FIXTURES/claude-session.jsonl" "$proj/$sid6.jsonl"
stop() { printf '{"session_id":"%s","cwd":"/home/user/widget-api","transcript_path":"%s","hook_event_name":"%s"}' \
  "$1" "$proj/$1.jsonl" "$2"; }
run_hook() { SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' "$APP" "$1"; }
run_hook "$(stop "$sid6" Stop)"
assert_eq "the first turn writes one row" "1" "$(grep -c "session=$sid6" "$LOG")"
first="$(grep "session=$sid6" "$LOG")"
tail -n 1 "$proj/$sid6.jsonl" >> "$proj/$sid6.jsonl"          # the session goes on
run_hook "$(stop "$sid6" Stop)"
assert_eq "a later turn adds none" "1" "$(grep -c "session=$sid6" "$LOG")"

section "session end refreshes the row a turn wrote: appended, last row wins"
run_hook "$(stop "$sid6" SessionEnd)"
assert_eq "one superseding row" "2" "$(grep -c "session=$sid6" "$LOG")"
last="$(grep "session=$sid6" "$LOG" | tail -n 1)"
assert_contains "it carries the grown size" "$last" "| size=$(stat -c%s "$proj/$sid6.jsonl")"
assert_eq "it keeps the first row's time" "${first%% | *}" "${last%% | *}"
assert_contains "and its topic" "$last" '"the retry backoff fires twice per failure — find out why"'
assert_eq "the catalogue lists the session once" "1" \
  "$(bash -c '. "$0/bin/lib.sh"; sj_log_catalogue' "$APP" | grep -c "$sid6")"
run_hook "$(stop "$sid6" SessionEnd)"
assert_eq "ending again with nothing new adds nothing" "2" "$(grep -c "session=$sid6" "$LOG")"
SCRUBJAY_TOPIC="Retry fired twice: one wrapper too many" run_hook "$(stop "$sid6" SessionEnd)"
assert_contains "/sjlog's essence still lands after a turn wrote the row" \
  "$(grep "session=$sid6" "$LOG" | tail -n 1)" '"Retry fired twice: one wrapper too many"'

section "per turn: a turn that finds the session busy leaves a mark instead of racing it"
sid7="77777777-2222-4333-8444-555555555555"; cp "$FIXTURES/claude-session.jsonl" "$proj/$sid7.jsonl"
lock="${TMPDIR:-/tmp}/scrubjay-publish-$sid7"
sleep 30 & holder=$!
mkdir -p "$lock"; echo "$holder" > "$lock/pid"
run_hook "$(stop "$sid7" Stop)"
check "the mark is left for the holder" test -e "$lock.pending"
assert_eq "and the busy turn wrote nothing" "0" "$(grep -c "session=$sid7" "$LOG")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
run_hook "$(stop "$sid7" Stop)"
assert_eq "a dead holder's lock is taken over" "1" "$(grep -c "session=$sid7" "$LOG")"
check "the mark is consumed"  bash -c '! test -e "$1"' _ "$lock.pending"
check "and the lock released" bash -c '! test -e "$1"' _ "$lock"

finish
