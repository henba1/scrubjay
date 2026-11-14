#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/sj.sh, the front door. What must hold: `sj ls` shows this machine's agents as sj-reap reads
# them (tmux session, attached marked), other hosts' relayed leases marked "as of", recent ended
# and exited ones, and what the reaper stopped with the way back; `sj attach` goes to the tmux
# session here, or over ssh by a KNOWN alias and never a guessed one; `sj resume` attaches instead of
# starting a second copy of a live session, refuses one running outside tmux unless --force, offers
# attach-or-hand-off for one live elsewhere, resumes a stopped one in its own folder, and hands off
# what is not here; an ambiguous prefix lists its candidates. tmux, ssh and claude are stubs: nothing
# here attaches to a real session or reaches a real host.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

SJ="$APP/bin/sj.sh"
export SCRUBJAY_RUN_DIR="$SANDBOX/run" SJ_REAP_TASKS_ROOT="$SANDBOX/tasks"
export SJ_KEEP_TMUX=faketmux SJ_SSH=fakessh SCRUBJAY_CLAUDE_BIN=fakeclaude
unset TMUX TMUX_PANE SCRUBJAY_SSH_HOSTS SCRUBJAY_KEEP
mkdir -p "$SANDBOX/stubbin" "$SCRUBJAY_RUN_DIR/live" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/-w"
export PATH="$SANDBOX/stubbin:$PATH"

# tmux: panes are "<pane_pid>\t<pane_id>\t<session>\t<attached>" lines in tmux.panes; what a client
# would have done goes to tmux.calls.
cat > "$SANDBOX/stubbin/faketmux" <<'EOF'
#!/usr/bin/env bash
db="$SANDBOX/tmux.panes"; touch "$db"
case "$1" in
  list-panes) case "$*" in *pane_start_command*) cat "$SANDBOX/tmux.empty" 2>/dev/null ;; *) cat "$db" ;; esac ;;
  has-session) n="${3#=}"; awk -F '\t' -v n="$n" '$3 == n {f=1} END {exit !f}' "$db" ;;
  capture-pane) echo '[scrubjay] claude exited with status 143. Press Enter to close this session.' ;;
  attach-session|switch-client) echo "$*" >> "$SANDBOX/tmux.calls" ;;
esac
EOF
# ssh: `-G <host>` gives a HostName for the hosts in ssh.aliases (a Host stanza), the name itself
# otherwise, as real ssh does; the BatchMode call is the remote `sj where`, answered from ssh.where.
cat > "$SANDBOX/stubbin/fakessh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -G ]; then
  if grep -qx "$2" "$SANDBOX/ssh.aliases" 2>/dev/null; then echo "hostname 192.168.0.9"; else echo "hostname $2"; fi
  exit 0
fi
echo "$*" >> "$SANDBOX/ssh.calls"
case "$*" in *BatchMode*) cat "$SANDBOX/ssh.where" 2>/dev/null ;; esac
EOF
cat > "$SANDBOX/stubbin/fakeclaude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$SANDBOX/claude.calls"
EOF
chmod +x "$SANDBOX/stubbin/"*

NOW="$(date +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.123Z; }
work="$SANDBOX/work"; mkdir -p "$work"; work="$(cd -P "$work" && pwd)"

# agent <sid> [status] [session] [attached] — a live process, its registry entry, pane and transcript
agent() {
  local sid="$1" st="${2:-idle}" session="${3-sj-claude-w}" att="${4:-0}" pid
  sleep 600 >/dev/null 2>&1 & pid=$!
  jq -nc --arg s "$sid" --argjson p "$pid" --arg st "$st" --arg c "$work" --argjson t "$(( (NOW - 600) * 1000 ))" \
    '{sessionId: $s, pid: $p, status: $st, statusUpdatedAt: $t, cwd: $c}' > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
  [ -n "$session" ] && printf '%s\t%%%s\t%s\t%s\n' "$pid" "$pid" "$session" "$att" >> "$SANDBOX/tmux.panes"
  transcript "$sid"
  echo "$pid"
}
transcript() {  # transcript <sid> [cwd] — a stopped session's transcript here
  printf '{"type":"user","sessionId":"%s","cwd":"%s","timestamp":"%s"}\n' "$1" "${2:-$work}" "$(iso $((NOW - 600)))" \
    > "$CLAUDE_CONFIG_DIR/projects/-w/$1.jsonl"
}
lease() {  # lease <dir> <sid> <state> <age-seconds> [cwd] [pid]
  mkdir -p "$1"
  jq -nc --arg s "$2" --arg st "$3" --argjson ts "$((NOW - $4))" --arg c "${5:-/home/u/proj}" --arg p "${6:-}" \
    '{sid: $s, harness: "claude", host: "x", state: $st, cwd: $c, pid: $p, start: "", ts: $ts}' > "$1/$2.lease"
}
reset() {
  local f
  for f in "$CLAUDE_CONFIG_DIR/sessions/"*.json; do [ -f "$f" ] && kill "$(jq -r .pid "$f")" 2>/dev/null; done
  rm -rf "$CLAUDE_CONFIG_DIR/sessions/"*.json "$CLAUDE_CONFIG_DIR/projects/-w/"* "$SANDBOX/tmux."* "$SANDBOX/ssh."* \
         "$SANDBOX/claude.calls" "${SCRUBJAY_RUN_DIR:?}/live/"* "$SCRUBJAY_RUN_DIR/reap.log" "${SCRUBJAY_LOCAL_CHATS:?}/"*
  : > "$SCRUBJAY_DATA/logs/testhost.log"
}
trap 'reset' EXIT
calls() { cat "$SANDBOX/$1.calls" 2>/dev/null; }
row() { bash "$SJ" ls 2>&1 | awk -v s="${1:0:8}" '$2 == s'; }

A=aaaa0001-0000-4000-8000-000000000001
B=bbbb0002-0000-4000-8000-000000000002
C=cccc0003-0000-4000-8000-000000000003
D=dddd0004-0000-4000-8000-000000000004
E=eeee0005-0000-4000-8000-000000000005
F=ffff0006-0000-4000-8000-000000000006

section "sj ls"
agent "$A" idle sj-claude-w >/dev/null
agent "$B" busy sj-claude-w-2 1 >/dev/null
agent "$C" idle "" >/dev/null
lease "$SCRUBJAY_LOCAL_CHATS/otherhost/live" "$D" idle 3600
lease "$SCRUBJAY_LOCAL_CHATS/otherhost/live" "$E" ended 7200
lease "$SCRUBJAY_LOCAL_CHATS/otherhost/live" "$F" ended $((3 * 86400))
echo probe > "$SCRUBJAY_LOCAL_CHATS/otherhost/live/probe.lease"
lease "$SCRUBJAY_LOCAL_CHATS/testhost/live" "$A" ended 60          # our own relayed copy: ignored
lease "$SCRUBJAY_RUN_DIR/live" 99990007-0000-4000-8000-000000000007 ended 300 "$work"
lease "$SCRUBJAY_RUN_DIR/live" 99990008-0000-4000-8000-000000000008 working 300 "$work" 999999
printf '%s\n' "2026-11-01 10:00 | testhost | $work | \"retry backoff fix\" | session=$A | harness=claude" > "$SCRUBJAY_DATA/logs/testhost.log"
out="$(bash "$SJ" ls 2>&1)"
assert_contains "has the columns" "$out" "HOST       SID      STATE    IDLE    TMUX"
assert_contains "a detached agent here, its tmux session and topic" "$(row "$A")" "idle     10m     sj-claude-w "
assert_contains "the topic from the catalogue" "$(row "$A")" "retry backoff fix"
assert_contains "an attached one is marked" "$(row "$B")" "working  10m     sj-claude-w-2*"
assert_contains "one outside tmux says so" "$(row "$C")" "(no tmux)"
assert_contains "another host's lease: as of" "$(row "$D")" "otherhost  dddd0004 idle     1h0m    as of"
assert_contains "another host's recent end" "$(row "$E")" "ended"
assert_eq "an end days ago is left out" "" "$(row "$F")"
assert_eq "our own relayed lease is not a second row" "1" "$(bash "$SJ" ls | grep -c "^testhost   aaaa0001")"
assert_contains "a local clean end" "$(row 99990007)" "ended"
assert_contains "a lease whose process is gone: exited" "$(row 99990008)" "exited"
printf '%s reaped %s pid 1 (sj-claude-old, idle 1d1h) — resume: cd %s && claude --resume %s — screen: /x\n' \
  "2026-11-14 09:00" "$E" "$work" "$E" > "$SCRUBJAY_RUN_DIR/reap.log"
printf '%s reaped %s pid 2 (sj-claude-w, idle 1d1h) — resume: cd %s && claude --resume %s — screen: /x\n' \
  "2026-11-14 09:00" "$A" "$work" "$A" >> "$SCRUBJAY_RUN_DIR/reap.log"
lease "$SCRUBJAY_RUN_DIR/live" "$E" ended 300 "$work"
out="$(bash "$SJ" ls 2>&1)"
assert_contains "what sj-reap stopped, with the way back" "$out" "sj resume eeee0005"
assert_contains "and the plain command" "$out" "claude --resume $E)"
assert_contains "its row says reaped" "$(bash "$SJ" ls | grep '^testhost   eeee0005')" "reaped"
case "$out" in *"sj resume aaaa0001"*) _no "a reaped session running again is not listed as stopped" "$out" ;;
  *) _ok "a reaped session running again is not listed as stopped" ;; esac
printf '4242\t%%42\tsj-claude-gone\t0\t%s\tbash sj-keep.sh --inner /x -- claude\n' "$NOW" > "$SANDBOX/tmux.empty"
assert_contains "a pane whose agent exited" "$(bash "$SJ" ls | grep sj-claude-gone)" "exited"
reset
assert_contains "nothing at all" "$(bash "$SJ" ls)" "no sessions known"

section "sj attach"
agent "$A" idle sj-claude-w >/dev/null
agent "$C" idle "" >/dev/null
bash "$SJ" attach sj-claude-w >/dev/null 2>&1
assert_eq "a tmux name here" "attach-session -t =sj-claude-w" "$(calls tmux)"; rm -f "$SANDBOX/tmux.calls"
bash "$SJ" attach aaaa0001 >/dev/null 2>&1
assert_eq "a sid8" "attach-session -t =sj-claude-w" "$(calls tmux)"; rm -f "$SANDBOX/tmux.calls"
TMUX=/tmp/x,1,0 bash "$SJ" attach "$A" >/dev/null 2>&1
assert_eq "from inside tmux: switch" "switch-client -t =sj-claude-w" "$(calls tmux)"; rm -f "$SANDBOX/tmux.calls"
out="$(bash "$SJ" attach cccc0003 2>&1)"; rc=$?
assert_contains "outside tmux: nothing to attach to" "$out" "outside tmux"
assert_eq "and a failure" "1" "$rc"
assert_eq "where: the session holding it" "sj-claude-w" "$(bash "$SJ" where aaaa0001)"
check_fails "where: none outside tmux" bash "$SJ" where cccc0003
lease "$SCRUBJAY_LOCAL_CHATS/otherhost/live" "$D" waiting 600
out="$(bash "$SJ" attach dddd0004 2>&1)"
assert_contains "elsewhere, no alias: no guess" "$out" "no SSH alias is known for 'otherhost'"
assert_contains "but the command to run there" "$out" "sj attach dddd0004"
assert_eq "and no ssh at all" "" "$(calls ssh)"
echo otherhost > "$SANDBOX/ssh.aliases"; echo sj-claude-proj-2 > "$SANDBOX/ssh.where"
bash "$SJ" attach dddd0004 >/dev/null 2>&1
assert_contains "elsewhere: asks that host which tmux session" "$(calls ssh | head -n 1)" "BatchMode=yes"
assert_contains "via its own sj where" "$(calls ssh | head -n 1)" "bin/sj.sh\" where $D"
assert_eq "then attaches over ssh" "-t otherhost tmux attach-session -t =sj-claude-proj-2" "$(calls ssh | sed -n 2p)"
rm -f "$SANDBOX/ssh."*
SCRUBJAY_SSH_HOSTS="nas=x otherhost=other-lan" bash "$SJ" attach dddd0004 >/dev/null 2>&1
assert_contains "SCRUBJAY_SSH_HOSTS names the alias" "$(calls ssh)" "other-lan"
rm -f "$SANDBOX/ssh."*; echo otherhost > "$SANDBOX/ssh.aliases"
out="$(bash "$SJ" attach dddd0004 2>&1)"
assert_contains "no tmux session there: says what to do" "$out" "found no tmux session"
assert_eq "and does not attach" "1" "$(calls ssh | grep -c .)"
reset
agent aaaa0001-0000-4000-8000-00000000000a >/dev/null
agent aaaa0001-0000-4000-8000-00000000000b idle sj-claude-w-2 >/dev/null
out="$(bash "$SJ" attach aaaa0001 2>&1)"; rc=$?
assert_contains "an ambiguous prefix lists the candidates" "$out" "aaaa0001-0000-4000-8000-00000000000b"
assert_eq "and stops" "2:" "$rc:$(calls tmux)"
check_fails "a prefix under 4 characters is refused" bash "$SJ" attach aaa
reset

section "sj resume"
agent "$A" idle sj-claude-w >/dev/null
out="$(bash "$SJ" resume aaaa0001 2>&1)"
assert_contains "live here in tmux: says so" "$out" "still running here (idle), in tmux session 'sj-claude-w'"
assert_eq "and attaches instead of a second copy" "attach-session -t =sj-claude-w:" "$(calls tmux):$(calls claude)"
reset
agent "$C" busy "" >/dev/null
out="$(bash "$SJ" resume cccc0003 2>&1)"; rc=$?
assert_contains "live outside tmux: refused" "$out" "will not start one"
assert_eq "exit 3, nothing started" "3:" "$rc:$(calls claude)"
bash "$SJ" resume --force cccc0003 >/dev/null 2>&1
assert_eq "--force: a second copy, in its folder" "$work|--resume $C" "$(calls claude)"
reset
lease "$SCRUBJAY_LOCAL_CHATS/otherhost/live" "$D" idle 600
transcript "$D"
out="$(bash "$SJ" resume dddd0004 </dev/null 2>&1)"; rc=$?
assert_contains "live elsewhere: says where, as of when" "$out" "was idle on 'otherhost' as of"
assert_contains "offers to attach there" "$out" "sj attach dddd0004"
assert_contains "or to hand off anyway" "$out" "sj resume --force dddd0004"
assert_eq "without a terminal: exit 3, nothing started" "3:" "$rc:$(calls claude)"
echo otherhost > "$SANDBOX/ssh.aliases"; echo sj-claude-proj > "$SANDBOX/ssh.where"
echo a | SJ_ASSUME_TTY=1 bash "$SJ" resume dddd0004 >/dev/null 2>&1
assert_contains "a: attaches there" "$(calls ssh)" "-t otherhost tmux attach-session -t =sj-claude-proj"
echo h | SJ_ASSUME_TTY=1 bash "$SJ" resume dddd0004 >/dev/null 2>&1
assert_eq "h: hands it off (here: its transcript)" "$work|--resume $D" "$(calls claude)"
rm -f "$SANDBOX/claude.calls"
echo q | SJ_ASSUME_TTY=1 bash "$SJ" resume dddd0004 >/dev/null 2>&1
assert_eq "q: nothing" "" "$(calls claude)"
lease "$SCRUBJAY_LOCAL_CHATS/otherhost/live" "$D" ended 600
reset
mkdir -p "$SANDBOX/proj"; proj="$(cd -P "$SANDBOX/proj" && pwd)"
transcript "$E" "$proj"
out="$( (cd "$work" && bash "$SJ" resume eeee0005 --model opus) 2>&1)"
assert_contains "stopped, transcript here: says so" "$out" "its transcript is here: resuming it in"
assert_eq "resumes in ITS folder, extra args kept" "$proj|--resume $E --model opus" "$(calls claude)"
rm -f "$SANDBOX/claude.calls"
transcript "$F" "$SANDBOX/gone"
out="$( (cd "$work" && bash "$SJ" resume ffff0006) 2>&1)"
assert_contains "its folder gone: handed to claude resume" "$out" "not here any more"
reset
mkdir -p "$SCRUBJAY_LOCAL_CHATS/otherhost/-home-user-widget-api"
cp "$FIXTURES/claude-session.jsonl" "$SCRUBJAY_LOCAL_CHATS/otherhost/-home-user-widget-api/11111111-2222-4333-8444-555555555555.jsonl"
printf '%s\n' "2026-10-01 10:00 | otherhost | /home/user/widget-api | \"retry backoff\" | session=11111111-2222-4333-8444-555555555555 | harness=claude" \
  > "$SCRUBJAY_DATA/logs/otherhost.log"
out="$( (cd "$work" && bash "$SJ" resume 11111111) 2>&1)"
assert_contains "not here: the cross-machine hand-off" "$out" "not on this machine: handing it off"
assert_eq "staged and resumed on the full id, here" "$work|--resume 11111111-2222-4333-8444-555555555555" "$(calls claude)"
rm -f "$SCRUBJAY_DATA/logs/otherhost.log"

section "help and the shell function"
assert_contains "help" "$(bash "$SJ" help)" "sj resume [--force]"
check_fails "no arguments: usage, non-zero" bash "$SJ"
check_fails "an unknown command" bash "$SJ" frobnicate
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { skip "$sh: sj is defined" "$sh not installed"; continue; }
  # shellcheck disable=SC2016  # expands in the inner shell
  assert_contains "$sh: sj is defined by the integration" "$("$sh" -c '. "$0"; typeset -f sj' "$APP/bin/sj-shell.sh" 2>&1)" "bin/sj.sh"
  # shellcheck disable=SC2016
  assert_eq "$sh: a function of yours named sj is left alone" "mine" "$("$sh" -c 'sj() { echo mine; }; . "$0"; sj' "$APP/bin/sj-shell.sh" 2>&1)"
done

finish
