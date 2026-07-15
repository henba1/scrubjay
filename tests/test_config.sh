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
