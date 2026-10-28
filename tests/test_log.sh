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

section "the row follows the topic: a new row only when it moved"
. "$APP/bin/lib.sh"
rlog="$SANDBOX/row.log"; t="$SANDBOX/grow.jsonl"; rsid="77777777-2222-4333-8444-555555555555"
urec() { jq -cn --arg t "$1" '{type:"user", message:{role:"user", content:[{type:"text", text:$t}]}}'; }
row() { sj_log_row "$rlog" "$rsid" /w "$t" claude testhost "2026-01-01 00:00" "${1:-}" refresh; }
urec "<command-name>/sjtable</command-name>
<command-args>head=10</command-args>" > "$t"
row; assert_eq "first row titled by the lookup" 1 "$(grep -c '"/sjtable head=10"' "$rlog")"
row; assert_eq "same topic: nothing written" 1 "$?"
assert_eq "same topic: still one row" 1 "$(grep -c "session=$rsid" "$rlog")"
urec "fix the nftables syntax error in the firewall config" >> "$t"
row; assert_eq "topic moved: a row is written" 0 "$?"
assert_contains "the new row carries the work" "$(tail -1 "$rlog")" '"fix the nftables syntax error in the firewall config"'
row "Fixed the nftables config"; assert_contains "an essence is marked" "$(tail -1 "$rlog")" "| essence=1"
urec "write a backup script for the postgres database dumps" >> "$t"
row; assert_contains "the fallback never replaces an essence" "$(tail -1 "$rlog")" '"Fixed the nftables config"'
assert_contains "and the essence mark stays" "$(tail -1 "$rlog")" "| essence=1"

section "with a model: billed only for new prose, never downgraded"
rsid="88888888-2222-4333-8444-555555555555"
ncalls() { if [ -f "$SANDBOX/claude.calls" ]; then wc -l < "$SANDBOX/claude.calls" | tr -d ' '; else echo 0; fi; }
stub_claude
urec "<command-name>/sjtable</command-name>" > "$t"
row; assert_eq "no prose: no model call" 0 "$(ncalls)"
urec "fix the nftables syntax error in the firewall config" >> "$t"
row; assert_contains "new prose: the model's title" "$(tail -1 "$rlog")" '"Retry backoff fix" | session='
assert_contains "and the prompt count it titled" "$(tail -1 "$rlog")" "| prompts=1"
row; assert_eq "no new prose: nothing written" 1 "$?"
assert_eq "no new prose: no second call" 1 "$(ncalls)"
urec "write a backup script for the postgres dumps" >> "$t"
STUB_CLAUDE=fail row
assert_contains "a failed call never downgrades a model title" "$(tail -1 "$rlog")" '"Retry backoff fix" | session='
STUB_CLAUDE="Firewall fix + postgres backups" row
assert_contains "new prose, new title: a row is appended" "$(tail -1 "$rlog")" \
  '"Firewall fix + postgres backups" | session='
rsid="99999999-2222-4333-8444-555555555555"
STUB_CLAUDE=fail row
last="$(tail -1 "$rlog")"
assert_contains "a failed first call falls back to the first prompt" "$last" \
  '"fix the nftables syntax error in the firewall config" | session='
case "$last" in *prompts=*) _no "a fallback row has no prompt count, so it is retried" "$last" ;;
  *) _ok "a fallback row has no prompt count, so it is retried" ;; esac
c0="$(ncalls)"; rsid="aaaaaaaa-2222-4333-8444-555555555555"
sj_log_row "$rlog" "$rsid" /w "$t" claude testhost "" ""
assert_eq "a per-turn (non-refresh) row never calls the model" "$c0" "$(ncalls)"
export SCRUBJAY_AI_TOPIC=0

section "the model's own child session fires no scrubjay hook"
sid7="77777777-3333-4333-8444-555555555555"; cp "$FIXTURES/claude-session.jsonl" "$proj/$sid7.jsonl"
SCRUBJAY_NO_HOOKS=1 SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(payload "$sid7")"
assert_eq "SessionEnd under SCRUBJAY_NO_HOOKS writes no row" 0 "$(grep -c "session=$sid7" "$LOG")"

section "a session that ends in a subdirectory is catalogued under where it started"
# The payload's cwd is the LIVE one. The row (and everything else the hook files) must use the
# session's origin, or the first SessionEnd after a `cd` would catalogue it under the wrong project.
sid6="66666666-2222-4333-8444-555555555555"
cp "$FIXTURES/claude-session.jsonl" "$proj/$sid6.jsonl"
SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(printf '{"session_id":"%s","cwd":"/home/user/widget-api/frontend","transcript_path":"%s"}' \
            "$sid6" "$proj/$sid6.jsonl")"
line="$(grep "session=$sid6" "$LOG")"
assert_contains "the row carries the origin cwd" "$line" "| /home/user/widget-api |"

section "a branched session records its parent; nothing else does"
# /branch stamps every copied record with forkedFrom.sessionId. A plain, resumed (same file) or
# /compact-ed (logicalParentUuid, same session) transcript carries no such field.
sid7="77777777-2222-4333-8444-555555555555"
cp "$FIXTURES/claude-branched.jsonl" "$proj/$sid7.jsonl"
SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(payload "$sid7")"
line="$(grep "session=$sid7" "$LOG")"
assert_contains "fork carries forked_from" "$line" "| forked_from=$sid"
assert_eq "plain session has no forked_from" "0" "$(grep "session=$sid " "$LOG" | grep -c forked_from)"
sid8="88888888-2222-4333-8444-555555555555"
{ cat "$FIXTURES/claude-session.jsonl"
  printf '{"parentUuid":null,"logicalParentUuid":"aaaaaaaa-0000-4000-8000-000000000002","uuid":"cccccccc-0000-4000-8000-000000000001","sessionId":"%s","type":"system","subtype":"compact_boundary","cwd":"/home/user/widget-api"}\n' "$sid8"
} > "$proj/$sid8.jsonl"
SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' \
  "$APP" "$(payload "$sid8")"
assert_eq "compacted session has no forked_from" "0" "$(grep "session=$sid8" "$LOG" | grep -c forked_from)"

"$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1
assert_contains "catalogue marks the fork" "$(grep "${sid7:0:8}" "$SCRUBJAY_DATA/logs/CATALOGUE.md")" "⑂${sid:0:8} "

section "per turn (Stop): the first turn writes the row, later turns leave it be"
# Stop fires at the end of every turn; the session must be catalogued (and relayed) from the first.
export SCRUBJAY_TURN_SETTLE=0
sidt="a1a1a1a1-2222-4333-8444-555555555555"; cp "$FIXTURES/claude-session.jsonl" "$proj/$sidt.jsonl"
stop() { printf '{"session_id":"%s","cwd":"/home/user/widget-api","transcript_path":"%s","hook_event_name":"%s"}' \
  "$1" "$proj/$1.jsonl" "$2"; }
run_hook() { SCRUBJAY_HARNESS=claude bash -c 'printf "%s" "$1" | bash "$0/hooks/log-session.sh" --detached' "$APP" "$1"; }
run_hook "$(stop "$sidt" Stop)"
assert_eq "the first turn writes one row" "1" "$(grep -c "session=$sidt" "$LOG")"
first="$(grep "session=$sidt" "$LOG")"
tail -n 1 "$proj/$sidt.jsonl" >> "$proj/$sidt.jsonl"          # the session goes on
run_hook "$(stop "$sidt" Stop)"
assert_eq "a later turn adds none" "1" "$(grep -c "session=$sidt" "$LOG")"

section "session end refreshes the row a turn wrote: appended, last row wins"
run_hook "$(stop "$sidt" SessionEnd)"
assert_eq "one superseding row" "2" "$(grep -c "session=$sidt" "$LOG")"
last="$(grep "session=$sidt" "$LOG" | tail -n 1)"
assert_contains "it carries the grown size" "$last" "| size=$(wc -c < "$proj/$sidt.jsonl" | tr -d ' ')"
assert_eq "it keeps the first row's time" "${first%% | *}" "${last%% | *}"
assert_contains "and its topic" "$last" '"the retry backoff fires twice per failure — find out why"'
assert_eq "the catalogue lists the session once" "1" \
  "$(bash -c '. "$0/bin/lib.sh"; sj_log_catalogue' "$APP" | grep -c "$sidt")"
run_hook "$(stop "$sidt" SessionEnd)"
assert_eq "ending again with nothing new adds nothing" "2" "$(grep -c "session=$sidt" "$LOG")"
SCRUBJAY_TOPIC="Retry fired twice: one wrapper too many" run_hook "$(stop "$sidt" SessionEnd)"
assert_contains "/sjlog's essence still lands after a turn wrote the row" \
  "$(grep "session=$sidt" "$LOG" | tail -n 1)" '"Retry fired twice: one wrapper too many"'

section "per turn: a turn that finds the session busy leaves a mark instead of racing it"
sidl="b2b2b2b2-2222-4333-8444-555555555555"; cp "$FIXTURES/claude-session.jsonl" "$proj/$sidl.jsonl"
lock="${TMPDIR:-/tmp}/scrubjay-publish-$sidl"
sleep 30 & holder=$!
mkdir -p "$lock"; echo "$holder" > "$lock/pid"
run_hook "$(stop "$sidl" Stop)"
check "the mark is left for the holder" test -e "$lock.pending"
assert_eq "and the busy turn wrote nothing" "0" "$(grep -c "session=$sidl" "$LOG")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
run_hook "$(stop "$sidl" Stop)"
assert_eq "a dead holder's lock is taken over" "1" "$(grep -c "session=$sidl" "$LOG")"
check "the mark is consumed"  bash -c '! test -e "$1"' _ "$lock.pending"
check "and the lock released" bash -c '! test -e "$1"' _ "$lock"

finish
