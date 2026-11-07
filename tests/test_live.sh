#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Session leases (bin/sj-live.sh). What must hold: each lifecycle event leaves the right state, the
# process named is the harness and not a shell that is gone a moment later, a lease reaches the
# archive where no transcript walker takes it for a session, and hooks stay silent.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
export SCRUBJAY_RUN_DIR="$SANDBOX/run"
S=11111111-2222-4333-8444-555555555555
LEASE="$SCRUBJAY_RUN_DIR/live/$S.lease"
field() { jq -r ".$1" "$LEASE"; }
hook() { printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/w"}' "$S" "$1" | bash "$APP/bin/sj-live.sh" hook; }

section "a lifecycle event leaves its state"
for pair in SessionStart:idle UserPromptSubmit:working PermissionRequest:waiting Stop:idle SessionEnd:ended; do
  hook "${pair%:*}"; assert_eq "${pair%:*}" "${pair#*:}" "$(field state)"
done
assert_eq "the folder" /w "$(field cwd)"
assert_eq "the machine" testhost "$(field host)"
before="$(cksum < "$LEASE")"; hook PreCompact
assert_eq "an event it has no state for changes nothing" "$before" "$(cksum < "$LEASE")"

section "what it refuses"
check_fails "an unknown state" bash "$APP/bin/sj-live.sh" mark "$S" sleeping
check_fails "an id that could leave the folder" bash "$APP/bin/sj-live.sh" mark "../../x" idle
assert_no_file "and wrote nothing outside" "$SANDBOX/x.lease"

section "the process named is the harness, not the shells between"
# A stand-in harness, not a shell by name: it runs a hook through `sh -c`, as a harness does.
cat > "$SANDBOX/run.py" <<'PY'
import os, subprocess, sys
print(os.getpid(), flush=True)
subprocess.run(["sh", "-c", 'bash "$0" mark "$1" working', sys.argv[1], sys.argv[2]])
PY
cp "$(command -v python3)" "$SANDBOX/fakeharness" 2>/dev/null
got="$("$SANDBOX/fakeharness" "$SANDBOX/run.py" "$APP/bin/sj-live.sh" "$S" 2>/dev/null)"
assert_eq "the nearest ancestor that is no shell" "$got" "$(field pid)"
SCRUBJAY_LIVE_PID=$$ bash "$APP/bin/sj-live.sh" mark "$S" idle
assert_eq "a caller that knows says so" "$$" "$(field pid)"
check "with the process's start time" test -n "$(field start)"

section "the hooks stay silent, and live-session.sh honours its opt-out"
out="$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$S" | bash "$APP/hooks/live-session.sh")"
assert_eq "nothing on stdout, which would be context" "" "$out"
assert_eq "and it marked the turn" working "$(field state)"
rm -f "$LEASE"
printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$S" | SCRUBJAY_NO_HOOKS=1 bash "$APP/hooks/live-session.sh"
assert_no_file "a topic's own child session marks nothing" "$LEASE"

section "the relay carries it, and no walker takes it for a transcript"
bash "$APP/bin/sj-live.sh" mark "$S" idle /w
src="$SANDBOX/t.jsonl"; cp "$FIXTURES/claude-session.jsonl" "$src"
SCRUBJAY_NOSHIP=0 bash "$APP/bin/ship-transcript.sh" "$src" -w "$S" testhost /w >/dev/null 2>&1
assert_file "shipped beside the host's records" "$SCRUBJAY_LOCAL_CHATS/testhost/live/$S.lease"
got="$(. "$APP/bin/lib.sh"; sj_archive_resolve "$SCRUBJAY_LOCAL_CHATS" "$S" | cut -f1)"
assert_eq "hand-off finds only the transcript" "testhost/-w/$S.jsonl" "$got"

section "a harness's own registry"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
echo "{\"pid\":$$,\"sessionId\":\"$S\",\"cwd\":\"/w\",\"status\":\"busy\",\"statusUpdatedAt\":1700000000000}" > "$CLAUDE_CONFIG_DIR/sessions/1.json"
echo '{"pid":7,"sessionId":"spare-one","status":"idle","spare":true}' > "$CLAUDE_CONFIG_DIR/sessions/2.json"
echo 'private' > "$CLAUDE_CONFIG_DIR/sessions/1.abc.key"
assert_eq "busy reads as working; a spare process is no session" \
  "$(printf 'claude\t%s\t%s\tworking\t1700000000\t/w' "$S" "$$")" "$(SCRUBJAY_HARNESSES=claude bash "$APP/bin/sj-live.sh" sessions)"

finish
