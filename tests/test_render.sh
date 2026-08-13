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

section "a source the renderer cannot read degrades to a placeholder"
# bin/ship-transcript.sh pipes the renderer's stdout straight into the archive. A renderer that
# exited non-zero on a vanished session would abort the ship for every OTHER session in the sweep,
# so both guards must print something and exit 0 rather than fail.
nojq="$SANDBOX/nojq"; mkdir -p "$nojq"     # a PATH with no jq on it
for spec in \
  "claude:render-transcript.sh:transcript not found:claude-session.jsonl" \
  "opencode:render-opencode.sh:export not found:opencode-export.json" \
  "codex:render-codex.sh:rollout not found:codex-rollout.jsonl"; do
  h="${spec%%:*}"; rest="${spec#*:}"; script="${rest%%:*}"
  rest="${rest#*:}"; msg="${rest%%:*}"; fx="${rest#*:}"

  out="$(bash "$APP/bin/$script" "$SANDBOX/no-such-session" 2>/dev/null)"; rc=$?
  assert_eq "$h: a missing source exits 0" "0" "$rc"
  assert_contains "$h: and names what was missing" "$out" "$msg"

  # $BASH by absolute path: the stripped PATH must not stop us finding the interpreter itself.
  out="$(PATH="$nojq" "$BASH" "$APP/bin/$script" "$FIXTURES/$fx" 2>/dev/null)"; rc=$?
  assert_eq "$h: a machine without jq exits 0" "0" "$rc"
  assert_contains "$h: and says jq is why" "$out" "jq unavailable"
done

section "a session with no turns still renders the shared shape"
# sjmcp parses `_N turns_`; an empty session must still carry the line rather than emit nothing.
printf '' > "$SANDBOX/empty.jsonl"
printf '%s' '{"info":{"id":"ses_empty"},"messages":[]}' > "$SANDBOX/empty-opencode.json"
for pair in "claude:$SANDBOX/empty.jsonl" "codex:$SANDBOX/empty.jsonl" "opencode:$SANDBOX/empty-opencode.json"; do
  h="${pair%%:*}"; fx="${pair#*:}"
  out="$(sj_adapter_call "$h" sjh_render "$fx" 2>/dev/null)"
  assert_contains "$h: an empty session still has a title" "$out" "# (no prompt)"
  check "$h: and still reports zero turns" grep -qx '_0 turns_' <<<"$out"
done

section "the title is one line, however the prompt was typed"
# The title is a Markdown heading AND what /sjrecall shows as the session name. A newline in it
# would split the heading and strand the rest of the prompt as body text.
# $'...' rather than "$(printf …)": command substitution strips the trailing newline, which is
# exactly the character this test needs to survive into the renderer.
long=$'fix the\nbroken   retry\tlogic and also a great many other things that run past the eighty character cap'
jq -cn --arg t "$long" '{type:"user",message:{content:$t}}' > "$SANDBOX/longtitle.jsonl"
jq -cn --arg t "$long" '{type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:$t}]}}' \
  > "$SANDBOX/longtitle-codex.jsonl"
jq -n --arg t "$long" '{info:{id:"ses_t"},messages:[{info:{role:"user"},parts:[{type:"text",text:$t}]}]}' \
  > "$SANDBOX/longtitle-opencode.json"
for pair in "claude:$SANDBOX/longtitle.jsonl" "codex:$SANDBOX/longtitle-codex.jsonl" "opencode:$SANDBOX/longtitle-opencode.json"; do
  h="${pair%%:*}"; fx="${pair#*:}"
  title="$(sj_adapter_call "$h" sjh_render "$fx" 2>/dev/null | head -1)"
  check "$h: the title collapses the whitespace" grep -qF 'fix the broken retry logic' <<<"$title"
  assert_eq "$h: the title is capped at 80 chars" "82" "${#title}"   # "# " + 80
done

section "tool output folds into the assistant stream"
# The invariant behind the whole readable layer: a tool_result arrives as a `type:"user"` record,
# but it is OUTPUT, not a prompt. If it opened a `## User` block the transcript would read as the
# user having said what the tool printed, and the turn count would double-count every tool call.
cat > "$SANDBOX/tools.jsonl" <<'JSONL'
{"type":"user","message":{"content":"run the thing"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"first assistant block"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"second assistant block"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom: exit 1"}]}}
JSONL
out="$(sj_adapter_call claude sjh_render "$SANDBOX/tools.jsonl")"
assert_eq "claude: tool output opens no second ## User" "1" "$(grep -cx '## User' <<<"$out")"
assert_eq "claude: consecutive assistant records merge into one block" "1" "$(grep -cx '## Assistant' <<<"$out")"
assert_contains "claude: a failed tool is labelled an error" "$out" "**⎿ error:**"
assert_contains "claude: the error output survives" "$out" "boom: exit 1"

section "codex renders every tool shape it can receive"
# Only `function_call` with a bash -lc argv is covered by the fixture; these are the other three
# wire shapes, and each takes a different branch of render_call/output_text.
cat > "$SANDBOX/codex-tools.jsonl" <<'JSONL'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"check disk"}]}}
{"type":"response_item","payload":{"type":"local_shell_call","action":{"command":["bash","-lc","df -h /srv"]}}}
{"type":"response_item","payload":{"type":"function_call","name":"grepper","arguments":"{\"command\":[\"rg\",\"-n\",\"TODO\"]}"}}
{"type":"response_item","payload":{"type":"function_call_output","output":[{"text":"line one"},{"text":"line two"}]}}
JSONL
out="$(sj_adapter_call codex sjh_render "$SANDBOX/codex-tools.jsonl")"
assert_contains "codex: local_shell_call is labelled shell" "$out" "**→ shell**"
assert_contains "codex: and its bash -lc script is unwrapped" "$out" "df -h /srv"
assert_contains "codex: a non-bash argv is joined, not dumped as JSON" "$out" "rg -n TODO"
assert_contains "codex: array-form tool output is joined into text" "$out" "line one
line two"

section "opencode renders a failed tool and falls back for a title"
cat > "$SANDBOX/oc-error.json" <<'JSON'
{"info":{"id":"ses_e","title":"fallback title"},
 "messages":[{"info":{"role":"assistant"},"parts":[
   {"type":"tool","tool":"bash","state":{"status":"error","input":{"command":"systemctl restart nope"},"error":"Unit nope not found"}}]}]}
JSON
out="$(sj_adapter_call opencode sjh_render "$SANDBOX/oc-error.json")"
assert_contains "opencode: an errored tool is labelled an error" "$out" "**⎿ error:**"
assert_contains "opencode: and carries the error text" "$out" "Unit nope not found"
# with no user turn to name the session, the export's own title is the only thing left
assert_contains "opencode: the title falls back to info.title" "$(head -1 <<<"$out")" "fallback title"

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
