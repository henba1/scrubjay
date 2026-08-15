#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The topic is the only handle a human can search a session by, and — for a session whose
# transcript never reached this archive — the only thing /sjrecall can rank it on at all. Two
# failures put 5 of every 6 sessions out of reach: the extractor could not read an ordinary
# session's prompt, and every reader then *hid* the rows it had left blank.
#
# This file pins both halves: what sj_session_topic can read out of a transcript, and what the
# readers do with a row that still has no topic (list it) versus one backfilled later (show the
# newer row, not the stale one).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

LOG="$SCRUBJAY_DATA/logs/testhost.log"

# One user record per line, in the Claude Code transcript shape. `meta`/`sidechain` mirror the
# isMeta / isSidechain flags Claude Code stamps on records the user did not type.
rec() {  # rec <text> [meta|sidechain]
  jq -cn --arg t "$1" --arg f "${2:-}" \
    '{type:"user", isMeta:($f=="meta"), isSidechain:($f=="sidechain"),
      message:{role:"user", content:[{type:"text", text:$t}]}}'
}

# ── extraction ─────────────────────────────────────────────────────────────────────────────────

section "an ordinary prompt survives the wrappers glued to it"
# A typed prompt routinely arrives with an injected block in the same record. Rejecting a record
# for opening with '<' threw the prompt away with the wrapper — this is the common case, and the
# reason most sessions logged "(no text)".
f="$SANDBOX/plain.jsonl"
{ rec "<system-reminder>injected context the user never typed</system-reminder>
the retry backoff fires twice per failure"; } > "$f"
assert_eq "the wrapper is stripped, the prompt is kept" \
  "the retry backoff fires twice per failure" "$(sj_session_topic "$f")"

section "an unknown injected block is still not a topic"
f="$SANDBOX/unknown.jsonl"
{ rec "<some-future-block>whatever this is</some-future-block>"; } > "$f"
assert_eq "a record that is all markup yields nothing" "" "$(sj_session_topic "$f")"

section "a slash command's expanded body is never the topic"
# Claude Code writes the invocation as one user record and the command's own markdown body as the
# next, flagged isMeta. Reading that body made '/sjrecall foo' log its command's prose as the
# session topic — a WRONG topic, which is worse than a blank one because nothing looks broken.
f="$SANDBOX/cmd.jsonl"
{ rec "<local-command-caveat>Caveat: local command output</local-command-caveat>" meta
  rec "<command-message>sjbrowse</command-message>
<command-name>/sjbrowse</command-name>
<command-args>chats head=5</command-args>"
  rec "The user wants to browse the scrubjay archive and pull a chosen item into the session." meta
} > "$f"
assert_eq "the invocation is the topic, args and all" \
  "/sjbrowse chats head=5" "$(sj_session_topic "$f")"

section "a command-only session is named by its command, not left blank"
f="$SANDBOX/clear.jsonl"
{ rec "<local-command-caveat>Caveat: local command output</local-command-caveat>" meta
  rec "<command-name>/clear</command-name>
<command-args></command-args>"
} > "$f"
assert_eq "a session that only ran /clear says so" "/clear" "$(sj_session_topic "$f")"

section "real work outranks the command that preceded it"
f="$SANDBOX/mixed.jsonl"
{ rec "<command-name>/model</command-name>
<command-args>opus</command-args>"
  rec "fix the nftables syntax error"
} > "$f"
assert_eq "prose wins over the slash command" "fix the nftables syntax error" "$(sj_session_topic "$f")"

section "a subagent's prompt is not the session's topic"
f="$SANDBOX/side.jsonl"
{ rec "search the codebase for retry handling" sidechain
  rec "why is the archive missing yesterday's sessions?"
} > "$f"
assert_eq "sidechain records are skipped" \
  "why is the archive missing yesterday's sessions?" "$(sj_session_topic "$f")"

section "a transcript with nothing to quote still yields nothing"
f="$SANDBOX/empty.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}' > "$f"
assert_eq "no prompt, no invented topic" "" "$(sj_session_topic "$f")"

# ── the row helpers ────────────────────────────────────────────────────────────────────────────

section "a topic cannot break the row it sits in"
t="$(sj_topic_sanitize 'weird | topic "with" pipes
and a newline')"
assert_eq "quotes dropped, pipes neutralized, one line" \
  'weird / topic with pipes and a newline' "$t"
assert_eq "and it is capped" "40" "$(printf '%s' "$(sj_topic_sanitize "$(printf 'x%.0s' $(seq 1 200))" 40)" | wc -c | tr -d ' ')"

section "retopic rewrites the topic and nothing else"
row='2026-07-15 22:36 | testhost | /home/user/widget-api | "(no text)" | session=abc | harness=claude | model=m | turns=5 | size=99'
new="$(sj_log_retopic "$row" "the retry backoff fires twice")"
assert_eq "only the topic field changed" \
  '2026-07-15 22:36 | testhost | /home/user/widget-api | "the retry backoff fires twice" | session=abc | harness=claude | model=m | turns=5 | size=99' \
  "$new"
check_fails "a line that is not a session row is refused" sj_log_retopic "just some prose" "x"

# ── the readers agree: blank rows are listed, and the newest row wins ──────────────────────────

section "a topic-less row is still a row"
cat > "$LOG" <<'EOF'
2026-08-01 09:00 | testhost | /home/user/widget-api | "(no text)" | session=11111111-2222-4333-8444-555555555555 | harness=claude | model=m | turns=4 | size=120
2026-08-02 10:00 | testhost | /home/user/other | "a real topic" | session=22222222-2222-4333-8444-555555555555 | harness=claude | model=m | turns=9 | size=340
EOF
"$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1
CAT="$SCRUBJAY_DATA/logs/CATALOGUE.md"
assert_contains "the catalogue keeps the topic-less session" "$(cat "$CAT")" "11111111"
assert_eq "sj_log_catalogue lists both sessions" "2" "$(sj_log_catalogue | wc -l | tr -d ' ')"

section "a backfilled row supersedes the blank one it replaces"
# The correction is APPENDED, never edited in place — logs/*.log ride git with merge=union, which
# only stays conflict-free while every host appends to its own file. A reader that missed the
# last-wins rule would keep showing the stale row and the backfill would look like a no-op.
sj_log_retopic \
  '2026-08-01 09:00 | testhost | /home/user/widget-api | "(no text)" | session=11111111-2222-4333-8444-555555555555 | harness=claude | model=m | turns=4 | size=120' \
  'the retry backoff fires twice per failure' >> "$LOG"
"$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1
assert_eq "still two sessions, not three" "2" "$(sj_log_catalogue | wc -l | tr -d ' ')"
assert_contains "the corrected topic is the one shown" "$(sj_log_catalogue)" "the retry backoff fires twice"
assert_eq "the catalogue shows the session once" "1" \
  "$(grep -c '11111111' "$CAT" | tr -d ' ')"
assert_contains "and with its new topic" "$(cat "$CAT")" "the retry backoff fires twice"

# ── the backfill pass ──────────────────────────────────────────────────────────────────────────

section "sj-topics reads the archived transcript and appends a corrected row"
cat > "$LOG" <<'EOF'
2026-08-03 11:00 | testhost | /home/user/widget-api | "(no text)" | session=33333333-2222-4333-8444-555555555555 | harness=claude | model=m | turns=4 | size=120
2026-08-04 11:00 | otherhost | /home/user/widget-api | "(no text)" | session=44444444-2222-4333-8444-555555555555 | harness=claude | model=m | turns=4 | size=120
EOF
# The archive layout the transports resolve against: <root>/<host>/<slug>/<sid>.jsonl
arch="$SCRUBJAY_LOCAL_CHATS/testhost/-home-user-widget-api"; mkdir -p "$arch"
cp "$FIXTURES/claude-session.jsonl" "$arch/33333333-2222-4333-8444-555555555555.jsonl"

out="$(bash "$APP/bin/sj-topics.sh" --dry-run 2>&1)"
assert_contains "a dry run says what it would write" "$out" "would set 33333333"
assert_eq "and writes nothing" "0" "$(grep -c 'the retry backoff' "$LOG" | tr -d ' ')"

out="$(bash "$APP/bin/sj-topics.sh" 2>&1)"
assert_contains "the real run authors the topic" "$out" "authored 1 topic(s)"
assert_contains "from the transcript's own first prompt" "$(sj_log_catalogue)" \
  "the retry backoff fires twice per failure"
assert_eq "the session still has exactly one row in the catalogue" "1" \
  "$(sj_log_catalogue | grep -c '33333333' | tr -d ' ')"

section "another host's rows are left alone unless asked for"
# Appending to a file this host does not own is what merge=union tolerates least gracefully, so
# --all-hosts has to be explicit. otherhost's row has no transcript here either way.
assert_eq "otherhost's row was not touched" "1" "$(grep -c 'session=44444444' "$LOG" | tr -d ' ')"
out="$(bash "$APP/bin/sj-topics.sh" --all-hosts 2>&1)"
assert_contains "with --all-hosts it is considered" "$out" "topic-less row(s) for every host"
assert_contains "but reported as unreachable, not failed" "$out" "not resolvable in this archive"

section "a second run has nothing left to do"
out="$(bash "$APP/bin/sj-topics.sh" 2>&1)"
assert_contains "it is idempotent" "$out" "nothing to do"

section "a truncated session id is never resolved by guesswork"
# Not hypothetical: a real row in the wild reads `session=t`. The archive matches a handle
# ANYWHERE in a filename (sj_archive_resolve), so a one-character id is a wildcard — it resolved
# to an arbitrary transcript and would have stamped that session's prompt onto an unrelated row,
# which reads as authored and so invites no second look. Short ids are unresolvable, not a guess.
printf '%s\n' \
  '2026-08-05 12:00 | testhost | /home/user/widget-api | "(no text)" | session=t' >> "$LOG"
out="$(bash "$APP/bin/sj-topics.sh" --dry-run 2>&1)"
assert_eq "the row is not given some other session's topic" "0" \
  "$(printf '%s' "$out" | grep -c 'would set t ' | tr -d ' ')"
assert_contains "it is reported as unresolvable" "$out" "not resolvable in this archive"

# ── the sjmcp contract ─────────────────────────────────────────────────────────────────────────
# sj_list(type="log") and bin/sj-catalogue.sh render the SAME logs/*.log. They disagreed: sj_list
# dropped every row whose topic was never authored, so /sjbrowse chats silently showed one session
# in six. Same source, same rows, or the omission is invisible to the caller.

section "sj_list shows the sessions the catalogue shows"
if need_cmd uv "sjmcp lists topic-less sessions"; then
  probe="$SANDBOX/probe-data/logs"; mkdir -p "$probe"
  cat > "$probe/testhost.log" <<'EOF'
2026-08-01 09:00 | testhost | /home/user/widget-api | "(no text)" | session=aaaaaaaa-2222-4333-8444-555555555555 | harness=claude | model=m | turns=4 | size=120
2026-08-02 10:00 | testhost | /home/user/other | "a real topic" | session=bbbbbbbb-2222-4333-8444-555555555555 | harness=claude | model=m | turns=9 | size=340
2026-08-01 09:00 | testhost | /home/user/widget-api | "backfilled later" | session=aaaaaaaa-2222-4333-8444-555555555555 | harness=claude | model=m | turns=4 | size=120
EOF
  json="$(SCRUBJAY_LOCAL_CHATS="" SCRUBJAY_MEMORY="" SCRUBJAY_DATA="$SANDBOX/probe-data" \
          uv run --script "$APP/mcp/sjmcp_server.py" --selftest 2>/dev/null)"
  assert_contains "the never-authored session is listed" "$json" '"sid": "aaaaaaaa"'
  assert_contains "alongside the one that had a topic" "$json" '"sid": "bbbbbbbb"'
  assert_contains "and the newer row's topic is the one reported" "$json" '"topic": "backfilled later"'
  # Two log lines for aaaaaaaa, one session: the count is sessions, not rows.
  assert_contains "duplicate rows collapse to one session" "$json" '"log_sessions": 2'
fi

finish
