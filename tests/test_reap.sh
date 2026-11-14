#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/sj-reap.sh — stray agents are saved, then stopped. What must hold: only a detached, idle agent
# inside an sj-* session is ever stopped; never one attached, mid-turn, at a permission prompt or with
# a background shell running; a duplicate copy of a conversation goes early, judged by its own status
# and not the shared transcript; a transcript's last record counts, not its mtime; before a stop, the
# screen is saved beside the transcript and the session published; warn and off stop nothing; a run
# never overlaps another; a detached sj-* pane whose agent already exited is closed after an hour,
# its screen saved first.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

REAP="$APP/bin/sj-reap.sh"
export SCRUBJAY_RUN_DIR="$SANDBOX/run" SJ_REAP_TASKS_ROOT="$SANDBOX/tasks" SCRUBJAY_REAP_TERM_WAIT=3
export SJ_REAP_MEMINFO="$SANDBOX/meminfo" SJ_REAP_PUBLISH="$SANDBOX/stubbin/publish" SJ_KEEP_TMUX=faketmux
export SJ_REAP_CRONTAB=fakecrontab
unset SCRUBJAY_REAP TMUX TMUX_PANE
mkdir -p "$SANDBOX/stubbin" "$SANDBOX/run" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/-w"
export PATH="$SANDBOX/stubbin:$PATH"
printf 'MemTotal: 8000000 kB\nMemAvailable: 4000000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$SJ_REAP_MEMINFO"

# A stub tmux: panes are lines "<pane_pid>\t<pane_id>\t<session>\t<attached>" in tmux.panes.
cat > "$SANDBOX/stubbin/faketmux" <<'EOF'
#!/usr/bin/env bash
db="$SANDBOX/tmux.panes"; touch "$db"
case "$1" in
  list-panes) case "$*" in *pane_start_command*) cat "$SANDBOX/tmux.empty" 2>/dev/null ;; *) cat "$db" ;; esac ;;
  capture-pane) shift; while [ $# -gt 0 ]; do [ "$1" = -t ] && t="$2"; shift; done
                printf 'screen of %s\n> an unsent draft\n' "$t"
                grep -q "	$t	" "$SANDBOX/tmux.empty" 2>/dev/null &&
                  echo '[scrubjay] claude exited with status 143. Press Enter to close this session.' ;;
  display-message) [ -f "$SANDBOX/tmux.attach-now" ] && echo 1 || echo 0 ;;
  kill-pane) printf '%s\n' "$3" >> "$SANDBOX/tmux.killed" ;;
esac
EOF
cat > "$SANDBOX/stubbin/publish" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$SANDBOX/published"
EOF
cat > "$SANDBOX/stubbin/fakecrontab" <<'EOF'
#!/usr/bin/env bash
f="$SANDBOX/crontab"; touch "$f"
case "$1" in -l) cat "$f" ;; -) cat > "$f.new" && mv "$f.new" "$f" ;; esac
EOF
chmod +x "$SANDBOX/stubbin/"*

NOW="$(date +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.123Z; }
# agent <sid> <idle-seconds> [status] [session] [attached] [record-age] — a live process, its registry
# entry, its pane and its transcript. Prints the pid. record-age: how old the transcript's last record is.
agent() {
  local sid="$1" idle="$2" st="${3:-idle}" session="${4-sj-claude-w}" att="${5:-0}" rec="${6:-$2}" pid
  sleep 600 >/dev/null 2>&1 & pid=$!
  jq -nc --arg s "$sid" --argjson p "$pid" --arg st "$st" --argjson t "$(( (NOW - idle) * 1000 ))" \
    '{sessionId: $s, pid: $p, status: $st, statusUpdatedAt: $t, cwd: "/w"}' > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
  [ -n "$session" ] && printf '%s\t%%%s\t%s\t%s\n' "$pid" "$pid" "$session" "$att" >> "$SANDBOX/tmux.panes"
  printf '{"type":"user","sessionId":"%s","timestamp":"%s"}\n' "$sid" "$(iso $((NOW - rec)))" \
    >> "$CLAUDE_CONFIG_DIR/projects/-w/$sid.jsonl"
  echo "$pid"
}
# every fake agent has a registry entry; that is how reset finds them (agent runs in $(…), so a
# list kept in a variable would never reach this shell)
reset() {
  local f
  for f in "$CLAUDE_CONFIG_DIR/sessions/"*.json; do
    [ -f "$f" ] || continue; pkill -P "$(jq -r .pid "$f")" 2>/dev/null; kill "$(jq -r .pid "$f")" 2>/dev/null
  done
  rm -f "$CLAUDE_CONFIG_DIR/sessions/"*.json "$CLAUDE_CONFIG_DIR/projects/-w/"*.jsonl "$SANDBOX/tmux.panes" \
        "$SANDBOX/tmux.killed" "$SANDBOX/published" "$SANDBOX/tmux.attach-now" "$SANDBOX/run/reap."*
  rm -rf "$CLAUDE_CONFIG_DIR/projects/-w/"*/ "$SANDBOX/tasks"
}
trap 'reset' EXIT
H=3600
verdict() { bash "$REAP" ls | awk -v p="$1" '$2 == p' | sed 's/.*  *\(keep\|warn\|reap\):/\1:/'; }

section "who is kept"
p1="$(agent aaaa1111-0000-4000-8000-000000000001 $((30 * H)) idle "")"
p2="$(agent aaaa1111-0000-4000-8000-000000000002 $((30 * H)) idle sj-claude-w 1)"
p3="$(agent aaaa1111-0000-4000-8000-000000000003 $((30 * H)) busy)"
p4="$(agent aaaa1111-0000-4000-8000-000000000004 $((30 * H)) waiting)"
p5="$(agent aaaa1111-0000-4000-8000-000000000005 $((1 * H)))"
assert_contains "outside an sj-keep session" "$(verdict "$p1")" "keep: not in an sj-keep session"
assert_contains "attached" "$(verdict "$p2")" "keep: attached"
assert_contains "mid-turn" "$(verdict "$p3")" "keep: working"
assert_contains "at a permission prompt" "$(verdict "$p4")" "keep: waiting"
assert_contains "idle 1 h" "$(verdict "$p5")" "keep: idle 1h"
reset
bash -c 'sh -c "sleep 600; :"; :' >/dev/null 2>&1 & bg=$!; sleep 0.3   # "; :" keeps each shell from exec-ing the next
jq -nc --argjson p "$bg" --argjson t "$(( (NOW - 30 * H) * 1000 ))" \
  '{sessionId: "aaaa1111-0000-4000-8000-000000000006", pid: $p, status: "idle", statusUpdatedAt: $t, cwd: "/w"}' \
  > "$CLAUDE_CONFIG_DIR/sessions/$bg.json"
printf '%s\t%%9\tsj-claude-w\t0\n' "$bg" >> "$SANDBOX/tmux.panes"
assert_contains "a background shell running" "$(verdict "$bg")" "keep: background shell running"
reset

section "warn and reap ages"
p1="$(agent bbbb2222-0000-4000-8000-000000000001 $((13 * H)))"
p2="$(agent bbbb2222-0000-4000-8000-000000000002 $((25 * H)))"
assert_contains "13 h: warned" "$(verdict "$p1")" "warn: idle 13h"
assert_contains "25 h: reaped" "$(verdict "$p2")" "reap: idle 1d1h"
reset
p1="$(agent bbbb2222-0000-4000-8000-000000000003 $((25 * H)) idle sj-claude-w 0 60)"
assert_contains "a fresh transcript record keeps it" "$(verdict "$p1")" "keep: idle 1m"
reset
p1="$(agent bbbb2222-0000-4000-8000-000000000004 $((25 * H)))"
touch "$CLAUDE_CONFIG_DIR/projects/-w/bbbb2222-0000-4000-8000-000000000004.jsonl"
assert_contains "a touched transcript (mtime only) does not" "$(verdict "$p1")" "reap: idle 1d1h"
mkdir -p "$SANDBOX/tasks/-w/bbbb2222-0000-4000-8000-000000000004/tasks"; echo out > "$SANDBOX/tasks/-w/bbbb2222-0000-4000-8000-000000000004/tasks/x.output"
assert_contains "a background task writing keeps it" "$(verdict "$p1")" "keep: idle 0m"
reset

section "duplicates"
S=cccc3333-0000-4000-8000-000000000001
k="$(agent $S 10 busy sj-claude-w-5 1)"
d1="$(agent $S $((2 * H)) idle sj-claude-w-3 0 10)"
d2="$(agent $S $((10 * 60)) idle sj-claude-w-4 0 10)"
assert_contains "the attached copy is kept" "$(verdict "$k")" "keep: attached"
assert_contains "a copy quiet 2 h goes, despite the shared fresh transcript" "$(verdict "$d1")" "reap: duplicate of pid $k, quiet 2h"
assert_contains "a copy quiet 10 min stays for now" "$(verdict "$d2")" "keep: duplicate of pid $k, quiet 10m"
reset
o="$(agent $S $((5 * H)) idle "")"
d="$(agent $S $((1 * H)))"
assert_contains "no attached copy: the one outside tmux is kept" "$(verdict "$d")" "reap: duplicate of pid $o"
reset

section "memory pressure"
p1="$(agent dddd4444-0000-4000-8000-000000000001 $((13 * H)))"
out="$(bash "$REAP" run --dry-run)"
assert_contains "no pressure: a 13 h session is only warned" "$out" "would warn dddd4444"
printf 'MemTotal: 8000000 kB\nMemAvailable: 800000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$SJ_REAP_MEMINFO"
out="$(bash "$REAP" run --dry-run)"
assert_contains "RAM under 15 %: reaped at the warning age" "$out" "would reap dddd4444"
assert_contains "and says why" "$out" "memory pressure"
printf 'MemTotal: 8000000 kB\nMemAvailable: 4000000 kB\nSwapTotal: 1000 kB\nSwapFree: 200 kB\n' > "$SJ_REAP_MEMINFO"
assert_contains "swap over 70 % used: the same" "$(bash "$REAP" run --dry-run)" "would reap dddd4444"
printf 'MemTotal: 8000000 kB\nMemAvailable: 4000000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$SJ_REAP_MEMINFO"
reset

section "reaping one"
S=eeee5555-0000-4000-8000-000000000001
p="$(agent $S $((25 * H)))"
out="$(bash "$REAP" run --dry-run)"
check "a dry run stops nothing" kill -0 "$p"
SCRUBJAY_REAP_NOTIFY="echo >> $SANDBOX/notified" bash "$REAP" run
sleep 0.5
check_fails "the process is gone" kill -0 "$p"
cap="$(ls "$CLAUDE_CONFIG_DIR/projects/-w/$S/"reaped-*.txt 2>/dev/null | head -1)"
assert_file "the screen is saved beside the transcript" "$cap"
assert_contains "with the unsent draft" "$(cat "$cap" 2>/dev/null)" "an unsent draft"
assert_contains "and the way back" "$(cat "$cap" 2>/dev/null)" "claude --resume $S"
assert_eq "the session was published first" "$S /w" "$(cat "$SANDBOX/published" 2>/dev/null)"
assert_eq "its pane closed" "%$p" "$(cat "$SANDBOX/tmux.killed" 2>/dev/null)"
assert_contains "a line in reap.log" "$(cat "$SANDBOX/run/reap.log")" "reaped $S pid $p"
assert_contains "naming the resume command" "$(cat "$SANDBOX/run/reap.log")" "cd /w && claude --resume $S"
assert_contains "and SCRUBJAY_REAP_NOTIFY is told" "$(cat "$SANDBOX/notified" 2>/dev/null)" "reaped $S"
assert_no_file "the lock is released" "$SANDBOX/run/reap.lock"
reset

p="$(agent $S $((25 * H)))"; touch "$SANDBOX/tmux.attach-now"
bash "$REAP" run
check "attached between the look and the act: left alone" kill -0 "$p"
assert_contains "and logged" "$(cat "$SANDBOX/run/reap.log")" "skipped $S pid $p: became active or attached"
reset

section "modes and the lock"
p="$(agent ffff6666-0000-4000-8000-000000000001 $((25 * H)))"
SCRUBJAY_REAP=off bash "$REAP" run
check "off: stops nothing" kill -0 "$p"
SCRUBJAY_REAP=warn bash "$REAP" run >/dev/null; SCRUBJAY_REAP=warn bash "$REAP" run >/dev/null
check "warn: stops nothing" kill -0 "$p"
assert_eq "warn: says so once, not every run" "1" "$(grep -c 'would reap ffff6666' "$SANDBOX/run/reap.log")"
assert_contains "a bad mode is refused" "$(SCRUBJAY_REAP=yes bash "$REAP" run 2>&1)" "is not on|warn|off"
mkdir "$SANDBOX/run/reap.lock"
bash "$REAP" run
check "another run holding the lock: this one does nothing" kill -0 "$p"
rmdir "$SANDBOX/run/reap.lock"; reset

section "empty panes (the agent already exited)"
# empty <pid> <session> <attached> <age> [start command] — a pane where sj-keep outlived its agent
empty() { printf '%s\t%%e%s\t%s\t%s\t%s\t%s\n' "$1" "$1" "$2" "$3" "$((NOW - $4))" \
            "${5:-/x/bin/sj-keep.sh --inner /run/f -- claude}" >> "$SANDBOX/tmux.empty"; }
sleep 600 >/dev/null 2>&1 & e1=$!
sleep 600 >/dev/null 2>&1 & e2=$!
sleep 600 >/dev/null 2>&1 & e3=$!
sleep 600 >/dev/null 2>&1 & e4=$!
bash -c 'sleep 600; :' >/dev/null 2>&1 & e5=$!; sleep 0.3
empty "$e1" sj-claude-old 0 $((2 * H))
empty "$e2" sj-claude-recent 0 600
empty "$e3" sj-claude-looking 1 $((2 * H))
empty "$e4" sj-claude-other 0 $((2 * H)) "bash -l"
empty "$e5" sj-claude-busy 0 $((2 * H))
out="$(bash "$REAP" ls)"
assert_contains "listed, with why it ended" "$out" "close: claude exited with status 143."
case "$out" in *"Press Enter"*) _no "without sj-keep's prompt text" "$out" ;; *) _ok "without sj-keep's prompt text" ;; esac
assert_contains "quiet 10 min: kept for now" "$out" "keep (closes at 1h0m)"
for n in looking other busy; do
  case "$out" in *"sj-claude-$n "*) _no "never listed: $n" "$out" ;; *) _ok "never listed: $n" ;; esac
done
bash "$REAP" run --dry-run >/dev/null
assert_no_file "a dry run closes nothing" "$SANDBOX/tmux.killed"
bash "$REAP" run
assert_eq "run closes only the old one" "%e$e1" "$(cat "$SANDBOX/tmux.killed" 2>/dev/null)"
cap="$(ls "$SANDBOX/run/reaped/"sj-claude-old-*.txt 2>/dev/null | head -1)"
assert_file "its last screen is saved first" "$cap"
assert_contains "the screen and the exit line" "$(cat "$cap" 2>/dev/null)" "exited with status 143"
assert_contains "and logged" "$(cat "$SANDBOX/run/reap.log")" "closed empty sj-claude-old (claude exited with status 143.)"
kill "$e1" "$e2" "$e3" "$e4" 2>/dev/null; pkill -P "$e5" 2>/dev/null; kill "$e5" 2>/dev/null
rm -f "$SANDBOX/tmux.empty" "$SANDBOX/tmux.killed"

section "cron"
echo "0 1 * * * keep-me" > "$SANDBOX/crontab"
bash "$REAP" install >/dev/null; bash "$REAP" install >/dev/null
assert_eq "install is idempotent" "1" "$(grep -c 'scrubjay sj-reap' "$SANDBOX/crontab")"
assert_contains "every 15 minutes" "$(cat "$SANDBOX/crontab")" "*/15 * * * *"
assert_contains "other lines are kept" "$(cat "$SANDBOX/crontab")" "keep-me"
bash "$REAP" uninstall >/dev/null
assert_eq "uninstall removes only its line" "0 1 * * * keep-me" "$(grep . "$SANDBOX/crontab")"

section "sj-doctor"
doc() { SCRUBJAY_KEEP=ssh bash "$APP/bin/sj-doctor.sh" harnesses 2>&1; }
assert_contains "kept agents, nothing reaping them: a failure with the fix" "$(doc)" "sj-reap.sh install"
bash "$REAP" install >/dev/null
assert_contains "installed: says so" "$(doc)" "stray kept agents checked every 15 min"
assert_contains "off: says what that costs" "$(SCRUBJAY_REAP=off doc)" "hold their memory"

finish
