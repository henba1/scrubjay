#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Stray agents: the sessions bin/sj-keep.sh kept alive and nobody came back to. Each holds a few
# hundred MB, and a box that runs out of memory resets. This finds them, saves what only exists in
# the running process, and then stops them.
#
#   usage: sj-reap.sh ls                 every agent process here, its idle age and what would happen
#          sj-reap.sh rows               the same as TSV, for bin/sj.sh: "agent" + the judged row, "empty" + an
#                                        exited pane (see judge and empties below)
#          sj-reap.sh run [--dry-run]    act on it (what cron runs every 15 minutes)
#          sj-reap.sh install|uninstall  the cron line
#
# Only agents inside an sj-* tmux session are ever touched. A plain terminal session is the user's.
# Never touched either: an attached session, a turn in progress or a permission prompt (the harness's
# own status), a background shell still running, or any write to the transcript, its subagents or its
# background tasks within the thresholds below.
#
# Strays, oldest first:
#   duplicate   the same conversation in more than one process (a resume while the first copy ran on).
#               The copies diverge and redo each other's work. Kept: the attached one, else one outside
#               tmux, else the newest. The rest go after SCRUBJAY_REAP_DUP_AFTER of quiet.
#   idle        detached and quiet for SCRUBJAY_REAP_AFTER; warned about at SCRUBJAY_REAP_WARN.
#   pressure    RAM available under SCRUBJAY_REAP_MEM_MIN % or swap over SCRUBJAY_REAP_SWAP_MAX % used:
#               idle ones go at the warning age, oldest first, until the pressure is gone.
#
# Reaping one, in order: (1) the tmux pane's screen and scrollback, an unsent draft included, saved as
# <sid>/reaped-<time>.txt beside the transcript, which the relay carries with the session; (2) the
# session published the way /sjlog does, since SessionEnd will not fire; (3) SIGTERM, SIGKILL after
# SCRUBJAY_REAP_TERM_WAIT seconds, and the pane closed; (4) a line in <run>/reap.log naming the resume
# command, and SCRUBJAY_REAP_NOTIFY (a command, given the line as $1) when set.
#
# Empty panes too: an sj-* session whose agent already exited (killed from outside, e.g. by an OOM
# killer, or failed) is held open by sj-keep's "press Enter to close" so its last screen can be read.
# After SCRUBJAY_REAP_EMPTY_AFTER of no output (default 1 h) that screen is saved to
# <run>/reaped/<session>-<time>.txt and the pane closed. Detached ones only.
#
# SCRUBJAY_REAP (env or ~/.config/scrubjay/config): on (default) | warn (log, never stop) | off.
# Thresholds in seconds: SCRUBJAY_REAP_WARN=43200 (12 h), SCRUBJAY_REAP_AFTER=86400 (24 h),
# SCRUBJAY_REAP_DUP_AFTER=1800 (30 min).
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
sj_load_config

MODE="${SCRUBJAY_REAP:-on}"
WARN="${SCRUBJAY_REAP_WARN:-43200}"
AFTER="${SCRUBJAY_REAP_AFTER:-86400}"
DUP_AFTER="${SCRUBJAY_REAP_DUP_AFTER:-1800}"
MEM_MIN="${SCRUBJAY_REAP_MEM_MIN:-15}"
SWAP_MAX="${SCRUBJAY_REAP_SWAP_MAX:-70}"
TERM_WAIT="${SCRUBJAY_REAP_TERM_WAIT:-30}"
EMPTY_AFTER="${SCRUBJAY_REAP_EMPTY_AFTER:-3600}"
TMUX_BIN="${SJ_KEEP_TMUX:-tmux}"            # tests point these at stubs
MEMINFO="${SJ_REAP_MEMINFO:-/proc/meminfo}"
CRONTAB="${SJ_REAP_CRONTAB:-crontab}"
TASKS_ROOT="${SJ_REAP_TASKS_ROOT:-${TMPDIR:-/tmp}/claude-$(id -u)}"
RUN="$(sj_progress_dir)"
LOG="$RUN/reap.log"
MARK="# scrubjay sj-reap"
NOW="$(date +%s)"
TAB="$(printf '\t')"

age() {  # age <seconds> -> 3d4h, 5h12m, 7m
  local s="$1"
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

# newest <path>… — the newest mtime (epoch) of any file under the paths, 0 when none
newest() {
  local p t best=0
  for p in "$@"; do
    [ -e "$p" ] || continue
    while IFS= read -r t; do t="${t%%.*}"; [ -n "$t" ] && [ "$t" -gt "$best" ] && best="$t"; done < <(
      find "$p" -maxdepth 3 -type f -printf '%T@\n' 2>/dev/null ||
      find "$p" -maxdepth 3 -type f -exec stat -f %m {} + 2>/dev/null)
  done
  printf '%s' "$best"
}

# pressure — 0 when memory is short (Linux /proc/meminfo; elsewhere never)
pressure() {
  [ -r "$MEMINFO" ] || return 1
  awk -v mmin="$MEM_MIN" -v smax="$SWAP_MAX" '
    /^MemTotal:/ {mt=$2} /^MemAvailable:/ {ma=$2} /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
    END { if (mt > 0 && ma * 100 / mt < mmin) exit 0
          if (st > 0 && (st - sf) * 100 / st > smax) exit 0
          exit 1 }' "$MEMINFO"
}

# panes — TSV <pane_pid> <pane_id> <session> <attached 0|1>
panes() {
  sj_has "$TMUX_BIN" || return 0
  "$TMUX_BIN" list-panes -a -F "#{pane_pid}${TAB}#{pane_id}${TAB}#{session_name}${TAB}#{session_attached}" 2>/dev/null
}

# pane_of <pid> <panes-tsv> — the pane line whose process is <pid> or one of its ancestors
pane_of() {
  local p="$1" line
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || return 1
    line="$(awk -F '\t' -v p="$p" '$1 == p {print; exit}' <<<"$2")"
    [ -n "$line" ] && { printf '%s' "$line"; return 0; }
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

# shell_child <pid> — 0 when a shell runs under the agent (a background command; MCP servers are
# uv/python/node and do not count)
shell_child() {
  local kids k
  kids="$(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$1" '$2 == p {print $1}')"
  for k in $kids; do
    case "$(ps -o comm= -p "$k" 2>/dev/null)" in bash|zsh|sh|dash|fish) return 0 ;; esac
    shell_child "$k" && return 0
  done
  return 1
}

# last_record <transcript> — the epoch of its newest record. Not the file's mtime: tools touch a
# transcript without adding to it (seen: a 4-day-idle session's file with today's mtime).
last_record() {
  tail -n 20 "$1" 2>/dev/null |
    jq -rs 'map(.timestamp? // empty | strings) | last // empty | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null |
    cut -d. -f1
}

started() { ps -o etimes= -p "$1" 2>/dev/null | tr -d ' ' || true; }   # seconds since start

# rows — one TSV line per live agent process ("-" where a field is empty):
#   sid pid state last session pane_id attached cwd transcript reg
# last = the newest sign of life: the process's own status change, the transcript's last record, a
# subagent or background-task write. reg = the process's own status change alone, which is what tells
# one copy of a conversation from another (they share the transcript).
rows() {
  local p h sid pid state epoch cwd line session pane attached t sdir last act rec
  p="$(panes)"
  for h in $(sj_harnesses); do
    [ "$h" = claude ] || continue   # the only adapter whose registry lists processes, for now
    ( sj_load_adapter "$h" 2>/dev/null || exit 0
      declare -F sjh_live_sessions >/dev/null 2>&1 || exit 0
      sjh_live_sessions 2>/dev/null | while IFS="$TAB" read -r sid pid state epoch cwd; do
        kill -0 "$pid" 2>/dev/null || continue
        session="" pane="" attached=0
        if line="$(pane_of "$pid" "$p")"; then
          IFS="$TAB" read -r _ pane session attached <<<"$line"
          [ "$attached" -gt 0 ] 2>/dev/null && attached=1 || attached=0
        fi
        t="$(sjh_find_live_transcript "$cwd" "$sid" 2>/dev/null || true)"
        sdir=""; [ -n "$t" ] && sdir="$(dirname "$t")/$sid"
        act="$(newest ${sdir:+"$sdir"} "$TASKS_ROOT"/*/"$sid"/tasks)"
        rec=""; [ -n "$t" ] && rec="$(last_record "$t")"
        last="${epoch:-0}"
        [ "$act" -gt "$last" ] && last="$act"
        [ -n "$rec" ] && [ "$rec" -gt "$last" ] 2>/dev/null && last="$rec"
        # "-" for an empty field: read with a tab IFS folds consecutive tabs into one
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sid" "$pid" "$state" "$last" "${session:--}" "${pane:--}" "$attached" "${cwd:--}" "${t:--}" "${epoch:-0}"
      done )
  done
}

# judge <rows> — the rows with three columns appended: <idle> <verdict reap|warn|keep> <reason>, oldest first
judge() {
  local all="$1" sid pid state last session pane attached cwd t reg idle keeper verdict reason dupes
  while IFS="$TAB" read -r sid pid state last session pane attached cwd t reg; do
    [ -n "$sid" ] || continue
    idle=$((NOW - last)); verdict=keep; reason=""
    # the keeper of a conversation held by several processes
    keeper=""; dupes="$(awk -F '\t' -v s="$sid" '$1 == s' <<<"$all")"
    if [ "$(printf '%s\n' "$dupes" | grep -c .)" -gt 1 ]; then
      keeper="$(awk -F '\t' '$7 == 1 {print $2; exit}' <<<"$dupes")"
      [ -n "$keeper" ] || keeper="$(awk -F '\t' '$5 !~ /^sj-/ {print $2; exit}' <<<"$dupes")"
      if [ -z "$keeper" ]; then
        local best="" bests="" d e
        for d in $(awk -F '\t' '{print $2}' <<<"$dupes"); do
          e="$(started "$d")"; e="${e:-999999999}"
          if [ -z "$bests" ] || [ "$e" -lt "$bests" ]; then best="$d"; bests="$e"; fi
        done
        keeper="$best"
      fi
    fi
    case "$session" in
      sj-*) ;;
      *) reason="not in an sj-keep session" ;;
    esac
    if [ -z "$reason" ]; then
      if   [ "$attached" = 1 ];      then reason="attached"
      elif [ "$state" != idle ];     then reason="$state"
      elif shell_child "$pid";       then reason="background shell running"
      elif [ -n "$keeper" ] && [ "$keeper" != "$pid" ]; then
        idle=$((NOW - reg))
        if [ "$idle" -ge "$DUP_AFTER" ]; then verdict=reap; reason="duplicate of pid $keeper, quiet $(age "$idle")"
        else reason="duplicate of pid $keeper, quiet $(age "$idle")"; fi
      elif [ "$idle" -ge "$AFTER" ]; then verdict=reap; reason="idle $(age "$idle")"
      elif [ "$idle" -ge "$WARN" ];  then verdict=warn; reason="idle $(age "$idle"), reaped at $(age "$AFTER")"
      else reason="idle $(age "$idle")"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sid" "$pid" "$state" "$last" "$session" "$pane" "$attached" "$cwd" "$t" "$reg" "$idle" "$verdict" "$reason"
  done <<<"$all" | sort -t "$TAB" -k11,11nr
}

log() { mkdir -p "$RUN" 2>/dev/null; printf '%s %s\n' "$(sj_epoch_stamp "$NOW")" "$1" >> "$LOG"; }
tell() {
  log "$1"
  [ -n "${SCRUBJAY_REAP_NOTIFY:-}" ] && sj_timeout 30 sh -c "$SCRUBJAY_REAP_NOTIFY \"\$1\"" _ "$1" >/dev/null 2>&1
  return 0
}

# still_reapable <pid> <pane_id> — re-read just before acting: idle in the harness's registry, detached
still_reapable() {
  local reg
  reg="$(sjh_config_dir 2>/dev/null)/sessions/$1.json"
  [ -f "$reg" ] && [ "$(jq -r '.status // "idle"' "$reg" 2>/dev/null)" = idle ] || return 1
  [ "$("$TMUX_BIN" display-message -p -t "$2" '#{session_attached}' 2>/dev/null || echo 0)" = 0 ]
}

reap() {  # reap <sid> <pid> <session> <pane> <cwd> <transcript> <reason> <idle>
  local sid="$1" pid="$2" session="$3" pane="$4" cwd="$5" t="$6" reason="$7" idle="$8" sdir cap=""
  [ "$t" = - ] && t=""
  sj_load_adapter claude 2>/dev/null || return 1
  still_reapable "$pid" "$pane" || { log "skipped $sid pid $pid: became active or attached"; return 1; }
  # (1) what only the screen holds
  if [ -n "$t" ]; then
    sdir="$(dirname "$t")/$sid"; mkdir -p "$sdir" 2>/dev/null
    cap="$sdir/reaped-$(date -u +%Y%m%dT%H%M%SZ).txt"
    { printf 'scrubjay sj-reap: host %s, pid %s, tmux %s, idle %s, %s\n' "$(sj_host)" "$pid" "$session" "$(age "$idle")" "$reason"
      printf 'resume: cd %s && claude --resume %s\n\n' "$cwd" "$sid"
      "$TMUX_BIN" capture-pane -p -J -S -10000 -t "$pane" 2>/dev/null; } > "$cap"
    # (2) published as /sjlog would, so the row, the relay and memory are final
    if [ -n "${SJ_REAP_PUBLISH:-}" ]; then "$SJ_REAP_PUBLISH" "$sid" "$cwd" "$t"
    else
      jq -nc --arg s "$sid" --arg c "$cwd" --arg t "$t" '{session_id: $s, cwd: $c, transcript_path: $t}' |
        (cd "$cwd" 2>/dev/null || cd "$HOME" || exit 0; SCRUBJAY_HARNESS=claude sj_timeout 300 bash "$APP/hooks/log-session.sh" --detached) >/dev/null 2>&1
    fi
  fi
  # (3) stop it, then close the pane sj-keep would hold open on a non-zero exit
  kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 "$TERM_WAIT"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  "$TMUX_BIN" kill-pane -t "$pane" 2>/dev/null
  # (4) say so, with the way back
  tell "reaped $sid pid $pid ($session, $reason) — resume: cd $cwd && claude --resume $sid${cap:+ — screen: $cap}"
}

# empties — TSV <pane_id> <session> <idle> <exit line>: detached sj-* panes where sj-keep outlived its
# agent (the pane's process has no children left), oldest first
empties() {
  sj_has "$TMUX_BIN" || return 0
  local ppid pane session att start act kids line
  "$TMUX_BIN" list-panes -a -F "#{pane_pid}${TAB}#{pane_id}${TAB}#{session_name}${TAB}#{session_attached}${TAB}#{window_activity}${TAB}#{pane_start_command}" 2>/dev/null |
    while IFS="$TAB" read -r ppid pane session att act start; do
      case "$session" in sj-*) ;; *) continue ;; esac
      case "$start" in *sj-keep.sh*--inner*) ;; *) continue ;; esac
      [ "${att:-0}" = 0 ] || continue
      kids="$(ps -eo ppid= 2>/dev/null | awk -v p="$ppid" '$1 == p' | wc -l | tr -d ' ')"
      [ "$kids" = 0 ] || continue
      line="$("$TMUX_BIN" capture-pane -p -t "$pane" 2>/dev/null | grep -F '[scrubjay]' | tail -n 1)"
      [ -n "$line" ] || continue        # still starting, or not sj-keep's own wait
      line="${line%% Press Enter*}"
      printf '%s\t%s\t%s\t%s\n' "$pane" "$session" "$((NOW - ${act:-NOW}))" "$line"
    done | sort -t "$TAB" -k3,3nr
}

close_empty() {  # close_empty <pane> <session> <idle> <exit line>
  local d cap
  d="$RUN/reaped"; mkdir -p "$d" 2>/dev/null
  cap="$d/$2-$(date -u +%Y%m%dT%H%M%SZ).txt"
  { printf 'scrubjay sj-reap: host %s, tmux %s, agent gone, no output for %s\n\n' "$(sj_host)" "$2" "$(age "$3")"
    "$TMUX_BIN" capture-pane -p -J -S -10000 -t "$1" 2>/dev/null; } > "$cap"
  "$TMUX_BIN" kill-pane -t "$1" 2>/dev/null
  log "closed empty $2 (${4#\[scrubjay\] }) — screen: $cap"
}

run() {  # run [--dry-run]
  local dry=0 all sid pid state last session pane attached cwd t reg verdict reason idle
  [ "${1:-}" = --dry-run ] && dry=1
  [ "$MODE" = off ] && { [ "$dry" = 1 ] && echo "SCRUBJAY_REAP is off"; return 0; }
  case "$MODE" in on|warn) ;; *) echo "sj-reap: SCRUBJAY_REAP='$MODE' is not on|warn|off" >&2; return 2 ;; esac
  sj_has jq || return 0
  # one run at a time (cron every 15 min, a reap waits up to TERM_WAIT per process)
  mkdir -p "$RUN" 2>/dev/null
  if ! mkdir "$RUN/reap.lock" 2>/dev/null; then
    [ -n "$(find "$RUN/reap.lock" -maxdepth 0 -mmin +60 2>/dev/null)" ] || return 0
    rmdir "$RUN/reap.lock" 2>/dev/null; mkdir "$RUN/reap.lock" 2>/dev/null || return 0
  fi
  trap 'rmdir "$RUN/reap.lock" 2>/dev/null' EXIT
  all="$(judge "$(rows)")"
  local under=1; pressure && under=0
  while IFS="$TAB" read -r sid pid state last session pane attached cwd t reg idle verdict reason; do
    [ -n "$sid" ] || continue
    if [ "$verdict" = warn ] && [ "$under" = 0 ]; then
      verdict=reap; reason="memory pressure, $reason"
    fi
    case "$verdict" in
      reap)
        if [ "$dry" = 1 ] || [ "$MODE" = warn ]; then
          echo "would reap $sid pid $pid ($session, $reason)"
          [ "$MODE" = warn ] && [ "$dry" = 0 ] && warn_once "$sid" "$pid" "would reap $sid pid $pid ($session, $reason) — SCRUBJAY_REAP=warn"
        else
          reap "$sid" "$pid" "$session" "$pane" "$cwd" "$t" "$reason" "$idle"
          # re-check after each pressure reap: stop once it is gone
          case "$reason" in "memory pressure"*) pressure || under=1 ;; esac
        fi ;;
      warn)
        if [ "$dry" = 1 ]; then echo "would warn $sid pid $pid ($session, $reason)"
        else warn_once "$sid" "$pid" "stray $sid pid $pid ($session, $reason) — attach: tmux attach -t $session"; fi ;;
    esac
  done <<<"$all"
  local epane esession eidle eline
  while IFS="$TAB" read -r epane esession eidle eline; do
    [ -n "$epane" ] && [ "$eidle" -ge "$EMPTY_AFTER" ] || continue
    if [ "$dry" = 1 ] || [ "$MODE" = warn ]; then echo "would close empty $esession (${eline#\[scrubjay\] })"
    else close_empty "$epane" "$esession" "$eidle" "$eline"; fi
  done < <(empties)
}

warn_once() {  # warn_once <sid> <pid> <line> — once per process, not every 15 minutes
  local f="$RUN/reap.warned"
  grep -qx "$1 $2" "$f" 2>/dev/null && return 0
  printf '%s %s\n' "$1" "$2" >> "$f"
  tell "$3"
}

ls_cmd() {
  local all sid pid state last session pane attached cwd t reg idle verdict reason v
  all="$(judge "$(rows)")"
  [ -n "$all" ] || [ -n "$(empties)" ] || { echo "no agent processes on $(sj_host)"; return 0; }
  printf '%-8s %-8s %-30s %-8s %-7s %s\n' SESSION PID TMUX STATE IDLE VERDICT
  while IFS="$TAB" read -r sid pid state last session pane attached cwd t reg idle verdict reason; do
    [ -n "$sid" ] || continue
    [ "$attached" = 1 ] && session="$session*"
    printf '%-8s %-8s %-30s %-8s %-7s %s\n' "${sid:0:8}" "$pid" "$session" "$state" "$(age "$idle")" "$verdict: $reason"
  done <<<"$all"
  local epane esession eidle eline
  while IFS="$TAB" read -r epane esession eidle eline; do
    [ -n "$epane" ] || continue
    if [ "$eidle" -ge "$EMPTY_AFTER" ]; then v="close"; else v="keep (closes at $(age "$EMPTY_AFTER"))"; fi
    printf '%-8s %-8s %-30s %-8s %-7s %s\n' "-" "-" "$esession" "exited" "$(age "$eidle")" "$v: ${eline#\[scrubjay\] }"
  done < <(empties)
  pressure && echo "memory pressure: idle sessions go at $(age "$WARN") instead of $(age "$AFTER")"
  echo "mode: SCRUBJAY_REAP=$MODE   (* = attached)"
}

cron_line() { printf '*/15 * * * * PATH=%s bash %s run >/dev/null 2>&1 %s' "$PATH" "$APP/bin/sj-reap.sh" "$MARK"; }

# rows_cmd — what ls shows, for a program: bin/sj.sh (`sj ls`) builds its table on it, so there is one
# reading of "which agent runs in which pane" and not two that drift apart.
rows_cmd() {
  local all
  all="$(judge "$(rows)")"
  [ -n "$all" ] && printf '%s\n' "$all" | sed "s/^/agent$TAB/"
  empties | sed "s/^/empty$TAB/"
  return 0
}

case "${1:-}" in
  ls) ls_cmd ;;
  rows) rows_cmd ;;
  run) shift; run "$@" ;;
  install)
    sj_has "$CRONTAB" || { echo "sj-reap: no crontab here; run 'sj-reap.sh run' from your scheduler instead" >&2; exit 1; }
    { "$CRONTAB" -l 2>/dev/null | grep -vF "$MARK"; cron_line; echo; } | "$CRONTAB" - && echo "sj-reap: every 15 minutes (crontab -l)" ;;
  uninstall)
    sj_has "$CRONTAB" || exit 0
    "$CRONTAB" -l 2>/dev/null | grep -vF "$MARK" | "$CRONTAB" - && echo "sj-reap: cron line removed" ;;
  -h|--help|'') awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0" | sed -n '4,40p' ;;
  *) echo "sj-reap: unknown command '$1' (ls, rows, run, install, uninstall)" >&2; exit 2 ;;
esac
