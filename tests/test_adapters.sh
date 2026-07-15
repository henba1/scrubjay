#!/usr/bin/env bash
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
          sjh_extra_artifacts sjh_find_live_transcript sjh_slug sjh_project_dir sjh_import_side
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

finish
