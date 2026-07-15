#!/usr/bin/env bash
# Config apply. The property that matters for every harness: idempotent, and additive — scrubjay
# owns its own keys and never clobbers config the user (or another tool) put there.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"   # sj_adapter_call lives here; without it every apply below silently no-ops

section "opencode: apply is additive and idempotent"
cfg="$OPENCODE_CONFIG_DIR/opencode.json"
mkdir -p "$OPENCODE_CONFIG_DIR"
# A config the user already tuned: their theme, their own plugin, their own MCP server.
cat > "$cfg" <<'JSON'
{ "theme": "tokyonight", "model": "anthropic/claude-opus-4-8",
  "plugin": ["their-own-plugin"],
  "mcp": { "playwright": { "type": "local", "command": ["npx","-y","@playwright/mcp"] } } }
JSON

sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true

check "user's theme survives"        bash -c 'jq -e ".theme == \"tokyonight\"" "$1" >/dev/null' _ "$cfg"
check "user's model survives"        bash -c 'jq -e ".model == \"anthropic/claude-opus-4-8\"" "$1" >/dev/null' _ "$cfg"
check "user's own plugin survives"   bash -c 'jq -e ".plugin | index(\"their-own-plugin\")" "$1" >/dev/null' _ "$cfg"
check "user's own MCP server survives" bash -c 'jq -e ".mcp.playwright" "$1" >/dev/null' _ "$cfg"
check "scrubjay plugin was added"    bash -c 'jq -e ".plugin | map(test(\"scrubjay.js\")) | any" "$1" >/dev/null' _ "$cfg"
check "config is still valid JSON"   jq empty "$cfg"
check "commands were generated"      test -f "$OPENCODE_CONFIG_DIR/commands/sjrecall.md"

first="$(cat "$cfg")"
sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true
assert_eq "a second apply changes nothing" "$first" "$(cat "$cfg")"

section "opencode: an unparseable config is refused, not clobbered"
printf '{ this is not json ' > "$cfg"
sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true
assert_eq "the broken file is left exactly as-is" "{ this is not json " "$(cat "$cfg")"

section "generated commands are translated into opencode's dialect"
rc="$OPENCODE_CONFIG_DIR/commands/sjrecall.md"
if [ -f "$rc" ]; then
  check "MCP tools namespaced sjmcp_ (not mcp__sjmcp__)" bash -c '! grep -q "mcp__sjmcp__" "$1"' _ "$rc"
  check "no allowed-tools frontmatter (opencode has no such key)" bash -c '! grep -q "^allowed-tools:" "$1"' _ "$rc"
else
  skip "command dialect checks" "sjrecall.md was not generated"
fi

section "opencode: data-repo settings (base + host overlay) merge under your own keys"
# base sets a shared default; the host overlay overrides it. A user key the data repo never mentions
# must survive; the host value must beat the base value.
printf '{"theme":"tokyonight","small_model":"user/should-be-overridden"}\n' > "$cfg"
mkdir -p "$SCRUBJAY_DATA/opencode" "$SCRUBJAY_DATA/hosts/testhost/opencode"
printf '{"share":{"a":1},"small_model":"base/model","plugin":["shared-plugin"]}\n' > "$SCRUBJAY_DATA/opencode/opencode.base.json"
printf '{"small_model":"host/model"}\n' > "$SCRUBJAY_DATA/hosts/testhost/opencode/opencode.json"
sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true
check "user key the data repo never mentions survives" bash -c 'jq -e ".theme == \"tokyonight\"" "$1" >/dev/null' _ "$cfg"
check "base default is applied"                        bash -c 'jq -e ".share.a == 1" "$1" >/dev/null' _ "$cfg"
check "host overlay beats the base value"              bash -c 'jq -e ".small_model == \"host/model\"" "$1" >/dev/null' _ "$cfg"
check "base plugin is unioned in, user plugins kept"   bash -c 'jq -e ".plugin | index(\"shared-plugin\")" "$1" >/dev/null' _ "$cfg"

section "opencode: instructions point at the shared AGENTS.md exactly once, keeping the user's own"
printf '{"instructions":["/their/own/notes.md"]}\n' > "$cfg"
mkdir -p "$SCRUBJAY_DATA/shared"; printf '# shared\n' > "$SCRUBJAY_DATA/shared/AGENTS.md"
sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true
sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true   # twice: must not accumulate
check "the user's own instruction survives" bash -c 'jq -e ".instructions | index(\"/their/own/notes.md\")" "$1" >/dev/null' _ "$cfg"
n_agents="$(jq -r --arg p "$SCRUBJAY_DATA/shared/AGENTS.md" '[.instructions[] | select(. == $p)] | length' "$cfg")"
assert_eq "shared AGENTS.md is present exactly once after two syncs" "1" "$n_agents"

section "opencode: a Claude agent is translated into opencode's dialect"
mkdir -p "$SCRUBJAY_DATA/claude-md/agents"
cat > "$SCRUBJAY_DATA/claude-md/agents/test-runner.md" <<'AG'
---
name: test-runner
description: Runs the test suite and reports failures concisely.
tools: Bash, Read, Grep, Glob
model: sonnet
---
You are a focused test-runner subagent.
AG
sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true
ag="$OPENCODE_CONFIG_DIR/agent/test-runner.md"
if [ -f "$ag" ]; then
  agc="$(cat "$ag")"
  assert_contains "description is preserved" "$agc" "Runs the test suite and reports failures concisely."
  check "mode: subagent added"                   grep -qx 'mode: subagent' "$ag"
  check "no invented model: line"                bash -c '! grep -q "^model:" "$1"' _ "$ag"
  check "no name: line (opencode takes it from the filename)" bash -c '! grep -q "^name:" "$1"' _ "$ag"
  check "allowlisted tool -> permission allow"   grep -qE '^[[:space:]]+bash: allow' "$ag"
  check "read allowlisted -> allow"              grep -qE '^[[:space:]]+read: allow' "$ag"
  check "unlisted tool -> permission deny (edit)"   grep -qE '^[[:space:]]+edit: deny' "$ag"
  check "unlisted tool -> permission deny (write)"  grep -qE '^[[:space:]]+write: deny' "$ag"
  check "unlisted tool -> permission deny (task)"    grep -qE '^[[:space:]]+task: deny' "$ag"
  check "the body survives the translation"      grep -q 'focused test-runner subagent' "$ag"
else
  skip "agent translation checks" "test-runner.md was not generated under agent/"
fi

section "opencode: a personal command overrides the app command on a name clash"
mkdir -p "$SCRUBJAY_DATA/claude-md/commands"
printf -- '---\ndescription: personal override\n---\nMINE-WINS marker\n' > "$SCRUBJAY_DATA/claude-md/commands/sjrecall.md"
sj_adapter_call opencode sjh_apply_config >/dev/null 2>&1 || true
check "data-repo command wins over the app's" grep -q 'MINE-WINS marker' "$OPENCODE_CONFIG_DIR/commands/sjrecall.md"

section "codex: hooks.json registration is additive and idempotent"
hooks="$CODEX_HOME/hooks.json"
mkdir -p "$CODEX_HOME"
echo '{"hooks":{"PreToolUse":[{"matcher":"shell","hooks":[{"type":"command","command":"/usr/local/bin/audit.py"}]}]}}' > "$hooks"

sj_adapter_call codex sjh_apply_config >/dev/null 2>&1 || true
check "user's PreToolUse hook survives" bash -c 'jq -e ".hooks.PreToolUse[0].hooks[0].command == \"/usr/local/bin/audit.py\"" "$1" >/dev/null' _ "$hooks"
check "SessionStart -> sync-session registered" bash -c 'jq -e "[.hooks.SessionStart[].hooks[].command] | map(test(\"sync-session\")) | any" "$1" >/dev/null' _ "$hooks"
check "Stop -> log-session registered"          bash -c 'jq -e "[.hooks.Stop[].hooks[].command] | map(test(\"log-session\")) | any" "$1" >/dev/null' _ "$hooks"
check "our commands carry SCRUBJAY_HARNESS=codex" bash -c 'jq -e "[.hooks.SessionStart[].hooks[].command] | map(test(\"SCRUBJAY_HARNESS=codex\")) | any" "$1" >/dev/null' _ "$hooks"

first="$(cat "$hooks")"
sj_adapter_call codex sjh_apply_config >/dev/null 2>&1 || true
assert_eq "a second apply changes nothing (no duplicate hooks)" "$first" "$(cat "$hooks")"

finish
