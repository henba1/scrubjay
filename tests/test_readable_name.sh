#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# The readable file's NAME, and the one property that matters about it: it is a pure function of
# the session.
#
# The readable rendering is rewritten on every publish — /sjlog can run several times, then session
# end runs again — and each publish recomputes the name from scratch. If the name can move, a
# publish stops overwriting and starts *adding*, and nothing prunes the readable tree (the rrsync
# receiver's key is write-only by design). What survives is two files for one session under the same
# `__<sid8>` handle, where the older is a truncated copy: /sjrecall then scores both and can rank
# the stale one higher, and resolve_ref returns whichever it iterates onto first.
#
# So every test here is about stability under things that used to move it: the clock, and a copy.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

sid="11111111-2222-4333-8444-555555555555"
osid="ses_66a71b6f4ffeq796jvvOpJQ04m"

section "the date comes from the session's own records, not the file"
# Each fixture's first record predates the file on disk, so any answer that is today's date (or the
# file's mtime) fails here.
assert_eq "claude: ISO-8601 timestamp inside the transcript" "2026-03-09" \
  "$(sj_transcript_date "$FIXTURES/claude-session.jsonl")"
assert_eq "codex: the session_meta line's timestamp" "2026-07-14" \
  "$(sj_transcript_date "$FIXTURES/codex-rollout.jsonl")"
# opencode is the one that carries epoch MILLISECONDS, in a single JSON document rather than JSONL.
assert_eq "opencode: .info.time.created, epoch ms" "2025-07-13" \
  "$(sj_transcript_date "$FIXTURES/opencode-export.json")"

section "touching the transcript does not rename it"
# The midnight case, made deterministic: mtime moves by a year, the name must not move at all.
cp "$FIXTURES/claude-session.jsonl" "$SANDBOX/t.jsonl"
before="$(sj_readable_relpath "$SANDBOX/t.jsonl" "$sid")"
touch -t 202801010005 "$SANDBOX/t.jsonl"
assert_eq "same relpath after the mtime jumps a year" "$before" \
  "$(sj_readable_relpath "$SANDBOX/t.jsonl" "$sid")"
assert_contains "and it is dated from the records" "$before" "2026-03-09_"

section "copying the transcript does not rename it either"
# The `local` transport ships with `cp -f` (no -p), so the archived copy's mtime is when it was
# SHIPPED. backfill-readable.sh reads that copy — under the old scheme it minted a second name.
cp "$FIXTURES/claude-session.jsonl" "$SANDBOX/copy.jsonl"   # fresh mtime, as a ship would leave it
assert_eq "the archived copy resolves to the same name" \
  "$(sj_readable_relpath "$FIXTURES/claude-session.jsonl" "$sid")" \
  "$(sj_readable_relpath "$SANDBOX/copy.jsonl" "$sid")"

section "a transcript with no usable timestamp still gets a date"
# A name component may never come out empty — that would collapse two sessions onto one path.
printf '{"type":"user","message":{"content":"hi"}}\n' > "$SANDBOX/bare.jsonl"
touch -t 202405060700 "$SANDBOX/bare.jsonl"
assert_eq "falls back to the file's mtime" "2024-05-06" "$(sj_transcript_date "$SANDBOX/bare.jsonl")"
: > "$SANDBOX/empty.jsonl"
assert_eq "an empty file still yields a date, not an empty component" "10" \
  "$(printf '%s' "$(sj_transcript_date "$SANDBOX/empty.jsonl")" | wc -c | tr -d ' ')"

section "shipping twice writes ONE readable file"
# The end-to-end statement of the whole bug: publish, publish again, one file.
ARCHIVE="$SCRUBJAY_LOCAL_CHATS"
for _ in 1 2; do
  SCRUBJAY_HARNESS=claude bash "$APP/bin/ship-transcript.sh" \
    "$FIXTURES/claude-session.jsonl" "-home-user-widget-api" "$sid" testhost /home/user/widget-api \
    >/dev/null 2>&1
done
assert_eq "one readable for one session" "1" \
  "$(find "$ARCHIVE/testhost/readable" -name '*11111111*.md' | wc -l | tr -d ' ')"

section "backfill prunes a stale duplicate from the old naming"
# Plant exactly what the mtime scheme used to leave behind: same topic, same handle, wrong date.
mkdir -p "$ARCHIVE/testhost/-home-user-widget-api"
cp "$FIXTURES/claude-session.jsonl" "$ARCHIVE/testhost/-home-user-widget-api/$sid.jsonl"
good="$(basename "$(sj_readable_relpath "$FIXTURES/claude-session.jsonl" "$sid")")"
stale="$ARCHIVE/testhost/readable/widget-api/2026-03-10_${good#*_}.md"
printf 'stale truncated copy\n' > "$stale"
# …and a file that merely SHARES the handle, which must survive: pruning on the handle alone would
# take it, and two sessions can share an 8-char prefix.
bystander="$ARCHIVE/testhost/readable/widget-api/2026-03-10_something-else__11111111.md"
printf 'different session\n' > "$bystander"

bash "$APP/bin/backfill-readable.sh" "$ARCHIVE" >/dev/null 2>&1
check_fails "the stale duplicate is gone" test -e "$stale"
check "the current rendering is there" test -s "$ARCHIVE/testhost/readable/widget-api/$good.md"
check "a file with a different topic is NOT touched" test -e "$bystander"

section "--no-prune renders without deleting"
printf 'stale again\n' > "$stale"
bash "$APP/bin/backfill-readable.sh" --no-prune "$ARCHIVE" >/dev/null 2>&1
check "the stale file survives --no-prune" test -e "$stale"

finish
