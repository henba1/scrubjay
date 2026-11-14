#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# SessionStart guard: is this conversation already running in another process?
#
# A resume (claude -c, --resume, a reconnect after a dropped SSH session) loads the transcript into a
# NEW process, whether or not the old one is still alive. If it is, there are now two copies of one
# conversation. Neither sees what the other does from then on, both append to the same transcript, and
# each will happily redo the other's work. On 2026-11-14 that is exactly what happened: two copies each
# started the same backup and Talk deployments, and a third missed the first one's last turn. The
# reaper (bin/sj-reap.sh) stops such a copy after 30 minutes. This says so the moment it starts.
#
# Output is Claude Code's hook JSON: `systemMessage` for the human, `additionalContext` for the model,
# which is told to raise it before doing any work. Nothing at all is printed when there is no other
# copy. It never fails and never blocks a session: any error is silence.
#
# Its own hook, not part of sync-session.sh: a hook's stdout is parsed as JSON only when all of it is
# JSON, and sync-session prints plain-text notes. bin/claude-sync.sh registers it.
#
# SCRUBJAY_LIVE_PID names this session's process when the caller knows it (tests). Otherwise it is the
# nearest ancestor that is not a shell, as bin/sj-live.sh finds it.
[ "${SCRUBJAY_NO_HOOKS:-0}" = "1" ] && exit 0
input="$(cat 2>/dev/null)" || input=""
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
. "$APP/bin/lib.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || exit 0
TMUX_BIN="${SJ_KEEP_TMUX:-tmux}"
TAB="$(printf '\t')"
NOW="$(date +%s)"

self_pid() {
  [ -n "${SCRUBJAY_LIVE_PID:-}" ] && { printf '%s' "$SCRUBJAY_LIVE_PID"; return; }
  local p="$PPID" up comm
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$p" -gt 1 ] 2>/dev/null || return
    read -r up comm < <(ps -o ppid=,comm= -p "$p" 2>/dev/null) || return
    case "${comm##*/}" in
      sh|bash|zsh|dash|-sh|-bash|-zsh|env|*.sh) p="$up" ;;
      *) printf '%s' "$p"; return ;;
    esac
  done
}

# tmux_of <pid> — "<session>\t<attached 0|1>" for the pane the process (or an ancestor) runs in
tmux_of() {
  local panes p="$1" line
  command -v "$TMUX_BIN" >/dev/null 2>&1 || return 1
  panes="$("$TMUX_BIN" list-panes -a -F "#{pane_pid}${TAB}#{session_name}${TAB}#{session_attached}" 2>/dev/null)" || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$p" -gt 1 ] 2>/dev/null || return 1
    line="$(awk -F '\t' -v p="$p" '$1 == p {print $2 "\t" ($3 > 0 ? 1 : 0); exit}' <<<"$panes")"
    [ -n "$line" ] && { printf '%s' "$line"; return 0; }
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

age() {
  local s="$1"
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

me="$(self_pid)"
sj_load_adapter "$(sj_harness)" 2>/dev/null || exit 0
declare -F sjh_live_sessions >/dev/null 2>&1 || exit 0

human="" model="" attach=""
while IFS="$TAB" read -r osid opid ostate oepoch _; do
  [ "$osid" = "$sid" ] && [ -n "$opid" ] && [ "$opid" != "$me" ] || continue
  kill -0 "$opid" 2>/dev/null || continue
  where="a terminal outside tmux"; how="close that terminal's session (or quit it there)"
  if t="$(tmux_of "$opid")"; then
    IFS="$TAB" read -r osess oatt <<<"$t"
    if [ "$oatt" = 1 ]; then where="tmux session $osess, attached elsewhere"
    else where="tmux session $osess, detached"; fi
    how="/exit here, then: tmux attach -t $osess"
    [ -z "$attach" ] && attach="$osess"
  fi
  quiet=$(( NOW - ${oepoch:-$NOW} )); [ "$quiet" -lt 0 ] && quiet=0
  case "$ostate" in
    working) doing="mid-turn right now" ;;
    waiting) doing="waiting at a permission prompt" ;;
    *)       doing="idle for $(age "$quiet")" ;;
  esac
  human="${human:+$human; }pid $opid ($where, $doing)"
  model="${model:+$model
}- pid $opid: $where, $doing. To continue there instead: $how"
done < <(sjh_live_sessions 2>/dev/null)

[ -n "$human" ] || exit 0

msg="scrubjay: this conversation is ALSO running in $human. Two copies diverge and redo each other's work."
[ -n "$attach" ] && msg="$msg Attach instead: /exit here, then tmux attach -t $attach"
ctx="IMPORTANT (scrubjay duplicate guard): this conversation ($sid) is already running in another process on $(sj_host):
$model
Two live copies of one conversation diverge: neither sees what the other does, both append to the same transcript, and work gets done twice. The other copy may have acted after the last turn you can see. Before doing anything else, tell the user about this in your first reply and ask whether to continue here or switch to the other copy. If they continue here, check the real state first (git log and status, files, running services) instead of trusting this transcript, and suggest stopping the other copy."

jq -nc --arg m "$msg" --arg c "$ctx" \
  '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
exit 0
