#!/usr/bin/env bash
# The readable renderers. All three must emit the SAME Markdown shape — a `# title`, a `_N turns_`
# line, and `## User` / `## Assistant` blocks — because that shared shape is the entire basis for
# /sjrecall searching across harnesses, and mcp/sjmcp_server.py parses the turn count off it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

render_check() {  # render_check <harness> <fixture> <topic-substring>
  local h="$1" fx="$2" topic="$3" out
  out="$(sj_adapter_call "$h" sjh_render "$fx" 2>/dev/null)"

  assert_contains "$h: has a top-level title" "$(printf '%s' "$out" | head -1)" "# "
  assert_contains "$h: title carries the prompt" "$out" "$topic"
  check "$h: emits a '_N turns_' line" grep -qE '^_[0-9]+ turns_' <<<"$out"
  check "$h: has a ## User block" grep -qx '## User' <<<"$out"
  check "$h: has a ## Assistant block" grep -qx '## Assistant' <<<"$out"
}

section "claude renderer"
render_check claude "$FIXTURES/claude-session.jsonl" "retry backoff"
out="$(sj_adapter_call claude sjh_render "$FIXTURES/claude-session.jsonl")"
assert_contains "claude: renders the tool command" "$out" "grep -rn 'def retry' src/"
check "claude: drops the injected <system-reminder>" bash -c "! grep -q 'injected context' <<<\"\$1\"" _ "$out"

section "opencode renderer"
render_check opencode "$FIXTURES/opencode-export.json" "healthcheck"
out="$(sj_adapter_call opencode sjh_render "$FIXTURES/opencode-export.json")"
assert_contains "opencode: renders the tool command" "$out" "cat docker-compose.yml"
check "opencode: drops reasoning parts" bash -c "! grep -q 'thinking that should not' <<<\"\$1\"" _ "$out"
check "opencode: drops synthetic user text" bash -c "! grep -q 'injected rules' <<<\"\$1\"" _ "$out"

section "codex renderer"
render_check codex "$FIXTURES/codex-rollout.jsonl" "retry backoff"
out="$(sj_adapter_call codex sjh_render "$FIXTURES/codex-rollout.jsonl")"
# codex wraps shell calls as ["bash","-lc","<script>"]; the renderer must show the script, not argv.
assert_contains "codex: unwraps bash -lc to the script" "$out" "grep -rn 'def retry' src/"
check "codex: drops reasoning" bash -c "! grep -q 'look for the retry decorator' <<<\"\$1\"" _ "$out"
check "codex: drops the injected <environment_context>" bash -c "! grep -q 'environment_context' <<<\"\$1\"" _ "$out"

section "the turn count sjmcp reads is real"
# sjmcp trusts the `_N turns_` line; if a renderer miscounts, recall shows the wrong size.
for pair in "claude:$FIXTURES/claude-session.jsonl" "opencode:$FIXTURES/opencode-export.json" "codex:$FIXTURES/codex-rollout.jsonl"; do
  h="${pair%%:*}"; fx="${pair#*:}"
  out="$(sj_adapter_call "$h" sjh_render "$fx")"
  claimed="$(printf '%s' "$out" | sed -nE 's/^_([0-9]+) turns_/\1/p' | head -1)"
  actual="$(printf '%s' "$out" | grep -cE '^## (User|Assistant)')"
  assert_eq "$h: '_N turns_' matches the ## blocks" "$actual" "$claimed"
done

finish
