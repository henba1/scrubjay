#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Leases: which sessions a harness holds open right now. A lease is a small file a lifecycle event
# rewrites, and the process named in it is what makes it true: /sjview checks that process, so a
# killed session stops being active without anyone saying so.
#
#   usage: sj-live.sh mark <sid> <working|waiting|idle|ended> [cwd]
#          sj-live.sh hook                 the same from a hook's JSON payload on stdin
#          sj-live.sh sessions             TSV <harness> <sid> <pid> <state> <epoch> <cwd>, from each
#                                          harness's own registry (optional: sjh_live_sessions)
#
# <run>/live/<sid>.lease, JSON. The relay carries it to <host>/live/ with each publish, so another
# machine sees when a session last ended a turn. The extension matters: the archive's walkers take
# any .json two levels down for a transcript.
#
# SCRUBJAY_LIVE_PID names the harness's process when the caller knows it (the opencode plugin).
# Otherwise it is the nearest ancestor that is not a shell. Best-effort: never fails a session.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
sj_load_config

# The harness's process: hooks run under a shell or two, which are gone a moment later.
owner_pid() {
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

mark() {  # mark <sid> <state> [cwd]
  local sid="$1" state="$2" cwd="${3:-}" dir pid start tmp
  case "$state" in working|waiting|idle|ended) ;; *) echo "sj-live: no such state: $state" >&2; return 2 ;; esac
  case "$sid" in ''|*[!A-Za-z0-9_-]*) echo "sj-live: not a session id: $sid" >&2; return 2 ;; esac
  dir="$(sj_progress_dir)/live"
  mkdir -p "$dir" 2>/dev/null || return 0
  pid="$(owner_pid)"
  # A process id comes round again: its start time tells the holder from a stranger.
  start=""; [ -n "$pid" ] && start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')"
  # A turn ending or stopping at a permission prompt: tell the human (bin/sj-notify.sh). From waiting
  # too, since Claude marks nothing when a permission is granted and the turn runs on. Detached: a
  # terminal that blocks on the write must not hold up the hook.
  if [ "${SCRUBJAY_NOTIFY:-off}" = on ] && [ -n "$pid" ]; then
    case "$state:$(jq -r '.state // ""' "$dir/$sid.lease" 2>/dev/null)" in
      idle:working|idle:waiting|waiting:working)
        nohup bash "$APP/bin/sj-notify.sh" "$pid" </dev/null >/dev/null 2>&1 & ;;
    esac
  fi
  tmp="$dir/.$sid.$$"
  jq -nc --arg sid "$sid" --arg harness "$(sj_harness)" --arg host "$(sj_host)" --arg state "$state" \
    --arg cwd "$cwd" --arg pid "$pid" --arg start "$start" --argjson ts "$(date +%s)" \
    '{sid: $sid, harness: $harness, host: $host, state: $state, cwd: $cwd, pid: $pid, start: $start, ts: $ts}' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$sid.lease" || rm -f "$tmp"
  # A session that died leaves its lease behind; nothing reads one this old.
  find "$dir" -name '*.lease' -mtime +7 -exec rm -f {} + 2>/dev/null
  return 0
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  mark)
    [ $# -ge 2 ] || { echo "usage: sj-live.sh mark <sid> <state> [cwd]" >&2; exit 2; }
    mark "$@" ;;
  hook)
    command -v jq >/dev/null 2>&1 || exit 0
    IFS=$'\t' read -r sid event cwd < <(jq -r '[.session_id // "", .hook_event_name // "", .cwd // ""] | @tsv' 2>/dev/null) || exit 0
    case "$event" in
      SessionStart|Stop) state=idle ;;
      UserPromptSubmit)  state=working ;;
      PermissionRequest) state=waiting ;;
      SessionEnd)        state=ended ;;
      *) exit 0 ;;
    esac
    mark "$sid" "$state" "$cwd" 2>/dev/null
    exit 0 ;;
  sessions)
    for h in ${SCRUBJAY_HARNESSES:-claude}; do
      ( sj_load_adapter "$h" 2>/dev/null || exit 0
        declare -F sjh_live_sessions >/dev/null 2>&1 || exit 0
        sjh_live_sessions 2>/dev/null | sed "s/^/$h$(printf '\t')/" )
    done ;;
  *) sed -n '8,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
