#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The session map in a browser, on demand (/sjview). Nothing runs until you ask: `start` launches a
# small local server (view/sj_view.py) in the background and opens it; it stops on `stop`, on the
# page's Stop button, or by itself after SCRUBJAY_VIEW_IDLE minutes without a request.
#
#   usage: sj-view.sh [start] [--port N] [--idle MIN] [--no-open]
#          sj-view.sh stop | status
#
# Listens on 127.0.0.1 only, port SCRUBJAY_VIEW_PORT (default 7787, the next free one if taken).
# On a machine you reach over SSH, forward it: ssh -L 7787:127.0.0.1:7787 <host>.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
sj_load_config

STATE="$(sj_progress_dir)/view.json"
LOGF="$(sj_progress_dir)/view.log"

cmd=start
case "${1:-}" in start|stop|status) cmd="$1"; shift ;; esac
port="${SCRUBJAY_VIEW_PORT:-7787}" idle="${SCRUBJAY_VIEW_IDLE:-30}" open=1
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; shift 2 ;;
    --idle) idle="${2:-}"; shift 2 ;;
    --no-open) open=0; shift ;;
    -h|--help) sed -n '7,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sj-view: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$port" in ''|*[!0-9]*) echo "sj-view: --port needs a number" >&2; exit 2 ;; esac
case "$idle" in ''|*[!0-9]*) echo "sj-view: --idle needs whole minutes (0 = never)" >&2; exit 2 ;; esac

# The running viewer's pid and url, or nothing when there is none (a stale file is removed).
running() {
  [ -f "$STATE" ] || return 1
  local pid; pid="$(jq -r '.pid // empty' "$STATE" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  rm -f "$STATE"; return 1
}
url() { jq -r '.url' "$STATE"; }

open_url() {
  [ "$open" = 1 ] || return 0
  local u="$1"
  if [ "$(uname -s)" = Darwin ]; then open "$u" >/dev/null 2>&1 &
  elif command -v wslview >/dev/null 2>&1; then wslview "$u" >/dev/null 2>&1 &
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$u" >/dev/null 2>&1 &
  else return 0; fi
}

report() {
  local u p i; u="$(url)"; p="$(jq -r '.port' "$STATE")"; i="$(jq -r '.idle // 30 | floor' "$STATE")"
  echo "scrubjay view: $u"
  if [ "$i" = 0 ]; then echo "  runs until /sjview stop or the page's Stop button"
  else echo "  stops by itself after $i min unused; /sjview stop or the page's Stop button ends it now"; fi
  [ -n "${SSH_CONNECTION:-}" ] && echo "  over SSH: ssh -L $p:127.0.0.1:$p $(sj_host), then open the address above"
  return 0
}

case "$cmd" in
  status)
    if running; then report; else echo "scrubjay view: not running"; fi
    exit 0 ;;
  stop)
    if running; then
      pid="$(jq -r '.pid' "$STATE")"; kill "$pid" 2>/dev/null
      for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      rm -f "$STATE"; echo "scrubjay view: stopped"
    else echo "scrubjay view: not running"; fi
    exit 0 ;;
esac

if running; then report; open_url "$(url)"; exit 0; fi

command -v python3 >/dev/null 2>&1 || { echo "sj-view: needs python3" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "sj-view: needs jq" >&2; exit 1; }

# The archive pointers sjmcp gets (bin/claude-sync.sh), resolved the same way.
chats="${SCRUBJAY_LOCAL_CHATS:-}"
if [ -z "$chats" ] && [ "${SCRUBJAY_TRANSCRIPT_BACKEND:-}" = git ]; then
  c="$(sj_chats)"; [ -n "$c" ] && [ -d "$c/.git" ] && chats="$c"
fi
data="$(sj_data)" || exit 1

mkdir -p "$(dirname "$STATE")"
# Its own session where there is setsid (not on macOS), so closing the agent or the terminal that
# ran /sjview does not take the viewer down with it; nohup covers the hang-up either way.
detach=(nohup); command -v setsid >/dev/null 2>&1 && detach=(setsid nohup)
for p in "$port" 0; do   # the usual port, else any free one
  rm -f "$STATE"
  SCRUBJAY_DATA="$data" SCRUBJAY_LOCAL_CHATS="$chats" SCRUBJAY_MEMORY="$(sj_memory)" \
  SCRUBJAY_HOST="$(sj_host)" SCRUBJAY_VIEW_NEXTCLOUD="${SCRUBJAY_VIEW_NEXTCLOUD:-}" \
  SCRUBJAY_VIEW_NEXTCLOUD_MAP="${SCRUBJAY_VIEW_NEXTCLOUD_MAP:-}" "${detach[@]}" python3 "$APP/view/sj_view.py" \
    --port "$p" --idle "$idle" --state "$STATE" >"$LOGF" 2>&1 </dev/null &
  pid=$!
  for _ in $(seq 100); do
    [ -f "$STATE" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  [ -f "$STATE" ] && break
done
if ! running; then
  echo "sj-view: the viewer did not start:" >&2; sed 's/^/  /' "$LOGF" >&2; exit 1
fi
[ -z "$chats" ] && echo "  (no archive on this machine: the map shows the catalogue; transcripts are not readable here)"
report
open_url "$(url)"
exit 0
