#!/usr/bin/env bash
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

finish
