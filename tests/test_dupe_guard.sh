#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# hooks/dupe-guard.sh — a session that starts while the same conversation runs in another process
# says so at once. What must hold: silence when there is no other live copy (no other process, the
# other one dead, or it is this process); otherwise one line of hook JSON whose systemMessage tells the
# human where the other copy is and how to attach to it, and whose additionalContext tells the model
# to raise it before doing any work; a copy mid-turn or at a prompt is named as such; it never fails.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

GUARD="$APP/hooks/dupe-guard.sh"
mkdir -p "$SANDBOX/stubbin" "$CLAUDE_CONFIG_DIR/sessions"
export PATH="$SANDBOX/stubbin:$PATH" SJ_KEEP_TMUX=faketmux SCRUBJAY_LIVE_PID=$$
unset TMUX TMUX_PANE
cat > "$SANDBOX/stubbin/faketmux" <<'EOT'
#!/usr/bin/env bash
[ "$1" = list-panes ] && cat "$SANDBOX/tmux.panes" 2>/dev/null
exit 0
EOT
chmod +x "$SANDBOX/stubbin/faketmux"

S=99999999-1111-4222-8333-444444444444
NOW="$(date +%s)"
# other <status> <idle-seconds> [session] [attached] — another live process holding $S. Prints its pid.
other() {
  local pid; sleep 600 >/dev/null 2>&1 & pid=$!
  jq -nc --arg s "$S" --argjson p "$pid" --arg st "$1" --argjson t "$(( (NOW - $2) * 1000 ))" \
    '{sessionId: $s, pid: $p, status: $st, statusUpdatedAt: $t, cwd: "/w"}' > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
  [ -n "${3:-}" ] && printf '%s\t%s\t%s\n' "$pid" "$3" "${4:-0}" >> "$SANDBOX/tmux.panes"
  echo "$pid"
}
reset() {
  local f
  for f in "$CLAUDE_CONFIG_DIR/sessions/"*.json; do [ -f "$f" ] && kill "$(jq -r .pid "$f")" 2>/dev/null; done
  rm -f "$CLAUDE_CONFIG_DIR/sessions/"*.json "$SANDBOX/tmux.panes"
}
trap reset EXIT
guard() { printf '{"session_id":"%s","source":"resume"}' "${1:-$S}" | bash "$GUARD"; }

section "silence when there is no other copy"
assert_eq "no other process" "" "$(guard)"
p="$(other idle 60 sj-claude-w)"
assert_eq "another conversation's process" "" "$(guard 00000000-1111-4222-8333-444444444444)"
kill "$p"; sleep 0.2
assert_eq "the other copy has exited" "" "$(guard)"
reset
jq -nc --arg s "$S" --argjson p $$ '{sessionId: $s, pid: $p, status: "idle", statusUpdatedAt: 0, cwd: "/w"}' \
  > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
assert_eq "the only holder is this process" "" "$(guard)"
rm -f "$CLAUDE_CONFIG_DIR/sessions/$$.json"
assert_eq "no session id in the payload" "" "$(printf '{}' | bash "$GUARD")"
assert_eq "no payload at all" "" "$(bash "$GUARD" </dev/null)"

section "another live copy"
p="$(other idle $((14 * 60)) sj-claude-w-4)"
out="$(guard)"
check "one line of valid hook JSON" bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.hookEventName == \"SessionStart\"" >/dev/null' _ "$out"
msg="$(printf '%s' "$out" | jq -r .systemMessage)"
ctx="$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)"
assert_contains "the human hears where it runs" "$msg" "pid $p (tmux session sj-claude-w-4, detached, idle for 14m)"
assert_contains "and how to attach" "$msg" "tmux attach -t sj-claude-w-4"
assert_contains "the model is told to raise it first" "$ctx" "Before doing anything else, tell the user"
assert_contains "and to check the real state" "$ctx" "check the real state first"
assert_contains "naming the conversation" "$ctx" "$S"
reset

p="$(other busy 5 sj-claude-w-3 1)"
msg="$(guard | jq -r .systemMessage)"
assert_contains "a copy mid-turn is named as such" "$msg" "attached elsewhere, mid-turn right now"
reset
p="$(other waiting 5 sj-claude-w-3)"
assert_contains "one at a permission prompt too" "$(guard | jq -r .systemMessage)" "waiting at a permission prompt"
reset
p="$(other idle 60)"
msg="$(guard | jq -r .systemMessage)"
assert_contains "outside tmux: says so" "$msg" "a terminal outside tmux"
case "$msg" in *"tmux attach"*) _no "and offers no attach command" "$msg" ;; *) _ok "and offers no attach command" ;; esac
reset
a="$(other idle 60 sj-claude-w-2)"; b="$(other idle 120 sj-claude-w-3)"
msg="$(guard | jq -r .systemMessage)"
assert_contains "two other copies: both named" "$msg" "pid $a"
assert_contains "the second too" "$msg" "pid $b"
reset

section "never in the way"
p="$(other idle 60 sj-claude-w)"
assert_eq "SCRUBJAY_NO_HOOKS: silent" "" "$(printf '{"session_id":"%s"}' "$S" | SCRUBJAY_NO_HOOKS=1 bash "$GUARD")"
rc=0; printf 'not json' | bash "$GUARD" >/dev/null 2>&1 || rc=$?
assert_eq "garbage in: exits 0" "0" "$rc"
rc=0; guard >/dev/null 2>&1 || rc=$?
assert_eq "with a copy found: exits 0" "0" "$rc"
reset

finish
