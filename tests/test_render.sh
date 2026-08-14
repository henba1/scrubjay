#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

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

# A failed `opencode export` writes a zero-byte file. Because this renderer reads one JSON document
# it runs jq without -s, so an empty file yields zero values to iterate and the program never runs:
# before the guard the output was nothing at all, which archives as a .md carrying neither a title
# nor the `_N turns_` line sjmcp parses. A broken export must not look like an empty session.
: > "$SANDBOX/zero-export.json"
zout="$(bash "$APP/bin/render-opencode.sh" "$SANDBOX/zero-export.json" 2>/dev/null)"; zrc=$?
assert_eq "opencode: a zero-byte export exits 0" "0" "$zrc"
assert_contains "opencode: and reports the export as empty" "$zout" "export empty"
# the non-empty-but-turnless case is a real session and must still render the shared shape
printf '%s' '{"info":{"id":"ses_empty"},"messages":[]}' > "$SANDBOX/no-turns.json"
nout="$(sj_adapter_call opencode sjh_render "$SANDBOX/no-turns.json" 2>/dev/null)"
assert_contains "opencode: a turnless export still gets a title" "$nout" "# (no prompt)"
check "opencode: and still reports zero turns" grep -qx '_0 turns_' <<<"$nout"

section "codex renderer"
render_check codex "$FIXTURES/codex-rollout.jsonl" "retry backoff"
out="$(sj_adapter_call codex sjh_render "$FIXTURES/codex-rollout.jsonl")"
# codex wraps shell calls as ["bash","-lc","<script>"]; the renderer must show the script, not argv.
assert_contains "codex: unwraps bash -lc to the script" "$out" "grep -rn 'def retry' src/"
check "codex: drops reasoning" bash -c "! grep -q 'look for the retry decorator' <<<\"\$1\"" _ "$out"
check "codex: drops the injected <environment_context>" bash -c "! grep -q 'environment_context' <<<\"\$1\"" _ "$out"

section "a NUL byte never reaches the rendering"
# Captured terminal output can carry a NUL (/proc/device-tree/* strings are NUL-terminated); the
# transcript stores it as \u0000 and jq decodes it back to a raw byte. One such byte makes rg and
# grep treat the whole rendering as binary and skip it in a recursive search, so the session drops
# out of /sjrecall while still reading fine through sj_get. Inject the escape the way a harness
# really would — into a tool-output string — and prove it does not survive. See #66.
for spec in \
  "claude:claude-session.jsonl:grep -rn 'def retry' src/" \
  "opencode:opencode-export.json:cat docker-compose.yml" \
  "codex:codex-rollout.jsonl:grep -rn 'def retry' src/"; do
  h="${spec%%:*}"; rest="${spec#*:}"; fx="${rest%%:*}"; anchor="${rest#*:}"
  # one dir per harness, holding one .md — otherwise the traversal check below could pass on a
  # sibling harness's clean rendering while this one is still binary
  d="$SANDBOX/nulcheck-$h"; mkdir -p "$d"
  poisoned="$d/poisoned.${fx##*.}"
  # textual splice: the escape lands inside an existing JSON string, so the fixture stays valid JSON
  awk -v a="$anchor" '!done && index($0,a) { sub(a, a "\\u0000"); done=1 } { print }' \
    "$FIXTURES/$fx" > "$poisoned"
  check "$h: fixture really carries the escape" grep -q 'u0000' "$poisoned"

  sj_adapter_call "$h" sjh_render "$poisoned" > "$d/out.md" 2>/dev/null
  # the payload must survive — only the NUL is dropped
  assert_contains "$h: renders the poisoned line" "$(cat "$d/out.md")" "$anchor"
  check "$h: rendering contains no NUL byte" \
    python3 -c 'import sys; sys.exit(1 if b"\x00" in open(sys.argv[1],"rb").read() else 0)' "$d/out.md"
  # the property that actually matters: recall greps directories, so traversal must still see it
  check "$h: a recursive grep still finds it" bash -c \
    'grep -rq --include="*.md" -F -- "$2" "$1"' _ "$d" "$anchor"
done

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
