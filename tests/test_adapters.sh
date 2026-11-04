#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The harness seam: every adapter implements the contract, and each recognizes its own transcript
# format and nobody else's. Detection is what a hand-off keys off — get it wrong and scrubjay feeds
# one agent's session to another (which it once did).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

section "every adapter implements the contract"
# The functions bin/ship-transcript.sh, hooks/log-session.sh and bin/sj-resume.sh actually call.
# An adapter missing one of these fails at runtime, inside a hook, where nobody sees the error.
REQUIRED="sjh_config_dir sjh_present sjh_apply_config sjh_transcript_ext sjh_session_handle
          sjh_session_slug sjh_session_topic sjh_session_cwd sjh_session_meta sjh_render
          sjh_extra_artifacts sjh_find_live_transcript sjh_list_sessions sjh_slug
          sjh_project_dir sjh_import_side
          sjh_resume_cmd sjh_context_cmd sjh_detect"

for h in $(sj_known_harnesses); do
  missing=""
  for fn in $REQUIRED; do
    sj_adapter_call "$h" declare -F "$fn" >/dev/null 2>&1 || missing="$missing $fn"
  done
  assert_eq "$h implements the full contract" "" "$missing"
done

section "each adapter detects its own format — and only its own"
declare -A EXPECT=(
  ["$FIXTURES/claude-session.jsonl"]=claude
  ["$FIXTURES/opencode-export.json"]=opencode
  ["$FIXTURES/codex-rollout.jsonl"]=codex
)
for f in "${!EXPECT[@]}"; do
  want="${EXPECT[$f]}"
  assert_eq "sj_detect_harness($(basename "$f")) = $want" "$want" "$(sj_detect_harness "$f")"

  # …and no OTHER adapter claims it. Two adapters answering "mine" would make detection
  # order-dependent, i.e. a silent coin-flip on which format a hand-off assumes.
  claimed=""
  for h in $(sj_known_harnesses); do
    sj_adapter_call "$h" sjh_detect "$f" 2>/dev/null && claimed="$claimed $h"
  done
  assert_eq "only $want claims $(basename "$f")" " $want" "$claimed"
done

check_fails "an unrecognized file is not attributed to a harness" \
  sj_detect_harness "$APP/README.md"

section "session handles"
# The handle is what /sjrecall shows and /sjresume takes. opencode ids are ses_<base62>, so the
# first 8 characters would be mostly the prefix — strip it, or handles carry 4 bits of signal.
assert_eq "claude handle is the first 8 of the uuid" "11111111" \
  "$(sj_adapter_call claude sjh_session_handle 11111111-2222-4333-8444-555555555555)"
assert_eq "opencode handle strips the ses_ prefix" "66a71b6f" \
  "$(sj_adapter_call opencode sjh_session_handle ses_66a71b6f4ffeq796jvvOpJQ04m)"
assert_eq "codex handle is the first 8 of the uuid" "7c4f1a2b" \
  "$(sj_adapter_call codex sjh_session_handle 7c4f1a2b-9d3e-4a10-b8c5-1e2f3a4b5c6d)"

section "reading a session's metadata"
assert_eq "claude cwd" "/home/user/widget-api" \
  "$(sj_adapter_call claude sjh_session_cwd "$FIXTURES/claude-session.jsonl")"
assert_eq "opencode cwd" "/home/user/widget-api" \
  "$(sj_adapter_call opencode sjh_session_cwd "$FIXTURES/opencode-export.json")"
assert_eq "codex cwd" "/home/user/widget-api" \
  "$(sj_adapter_call codex sjh_session_cwd "$FIXTURES/codex-rollout.jsonl")"

# The topic is the first thing the user actually TYPED. Every harness injects its own context as a
# user message (<system-reminder>, <project-context>, <environment_context>) — a topic extractor
# that takes those makes the whole catalogue unreadable.
assert_eq "claude topic skips the injected <system-reminder>" \
  "the retry backoff fires twice per failure — find out why" \
  "$(sj_adapter_call claude sjh_session_topic "$FIXTURES/claude-session.jsonl")"
assert_eq "opencode topic skips the synthetic part" \
  "add a healthcheck to the compose file" \
  "$(sj_adapter_call opencode sjh_session_topic "$FIXTURES/opencode-export.json")"
assert_eq "codex topic skips the injected <environment_context>" \
  "the retry backoff fires twice per failure — find out why" \
  "$(sj_adapter_call codex sjh_session_topic "$FIXTURES/codex-rollout.jsonl")"

# Catalogue metadata (model + turns) feeds the session-log columns that /sjbrowse shows. Each
# harness reads model from a different place — Claude's per-message model, opencode's
# providerID/modelID, codex's turn_context — but all emit the same TSV shape.
section "catalogue metadata (sjh_session_meta → model, turns)"
assert_eq "claude model is the answering model" "claude-opus-4-8" \
  "$(sj_adapter_call claude sjh_session_meta "$FIXTURES/claude-session.jsonl" | cut -f1)"
assert_eq "claude turns count" "5" \
  "$(sj_adapter_call claude sjh_session_meta "$FIXTURES/claude-session.jsonl" | cut -f2)"
assert_eq "opencode model is provider/model" "anthropic/claude-opus-4-8" \
  "$(sj_adapter_call opencode sjh_session_meta "$FIXTURES/opencode-export.json" | cut -f1)"
assert_eq "opencode turns count" "2" \
  "$(sj_adapter_call opencode sjh_session_meta "$FIXTURES/opencode-export.json" | cut -f2)"
assert_eq "codex model from turn_context" "gpt-5-codex" \
  "$(sj_adapter_call codex sjh_session_meta "$FIXTURES/codex-rollout.jsonl" | cut -f1)"
assert_eq "codex turns count" "4" \
  "$(sj_adapter_call codex sjh_session_meta "$FIXTURES/codex-rollout.jsonl" | cut -f2)"

section "the live session is the one the harness names, never a guess at another"
. "$APP/bin/lib.sh"
pj="$CLAUDE_CONFIG_DIR/projects"; mkdir -p "$pj/-w-a" "$pj/-w-b"
mine="aaaaaaaa-0000-4000-8000-000000000001"; other="bbbbbbbb-0000-4000-8000-000000000002"
printf '{"type":"user","cwd":"/w/a","sessionId":"%s"}\n' "$mine" > "$pj/-w-a/$mine.jsonl"
sleep 1
# Another session, newer, whose records mention the same folder (it read the first one's).
printf '{"type":"user","cwd":"/w/b","note":{"cwd":"/w/a"}}\n' > "$pj/-w-b/$other.jsonl"
live() { sj_adapter_call claude sjh_find_live_transcript "$@"; }
assert_eq "without an id: the guess picks the newest mention (why the id matters)" "$pj/-w-b/$other.jsonl" "$(live /w/a)"
assert_eq "with the id: its own transcript" "$pj/-w-a/$mine.jsonl" "$(live /w/a "$mine")"
assert_eq "an id that is not here: nothing, not a stand-in" "" "$(live /w/a cccccccc-0000-4000-8000-000000000003)"
assert_eq "no match and no id: nothing, not the newest transcript anywhere" "" "$(live /w/nowhere)"
assert_eq "Claude Code's id is the live one" "$mine" "$(SCRUBJAY_HARNESS=claude CLAUDE_CODE_SESSION_ID="$mine" sj_live_sid)"
assert_eq "an explicit SCRUBJAY_SESSION_ID wins" "$other" \
  "$(SCRUBJAY_HARNESS=claude CLAUDE_CODE_SESSION_ID="$mine" SCRUBJAY_SESSION_ID="$other" sj_live_sid)"
assert_eq "another harness does not borrow Claude's id" "" "$(SCRUBJAY_HARNESS=opencode CLAUDE_CODE_SESSION_ID="$mine" sj_live_sid)"
out="$(cd /w 2>/dev/null; SCRUBJAY_HARNESS=claude CLAUDE_CODE_SESSION_ID="$mine" SCRUBJAY_NOSHIP=1 SCRUBJAY_LOG_NOGIT=1 \
  SCRUBJAY_TOPIC="Mine" bash -c 'cd /tmp && bash "$1/hooks/publish-now.sh"' _ "$APP" 2>&1)"
assert_contains "/sjlog publishes the session it runs in" "$out" "${mine:0:8}"

finish
