#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The session map in a browser, on demand (/sjview). Nothing runs until you ask: `start` launches a
# small local server (view/sj_view.py) in the background and opens it; it stops on `stop`, on the
# page's Stop button, or by itself after SCRUBJAY_VIEW_IDLE minutes without a request.
#
#   usage: sj-view.sh [start] [PROJECT] [--port N] [--idle MIN] [--no-open] [--json]
#          sj-view.sh stop | status [--json]
#
# PROJECT opens the map on that project alone. It need not be spelled right: it matches a
# project folder's name ignoring case and punctuation, then as part of one, then by likeness;
# the newest project wins a tie.
# --json is for front-ends (an editor that opens the address itself): stdout is one JSON object,
# {"running":true,"url":…,"port":…,"idle":…,"ssh":"ssh -L …"|null,"project":…|null} or
# {"running":false}, and start never opens a browser.
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
port="${SCRUBJAY_VIEW_PORT:-7787}" idle="${SCRUBJAY_VIEW_IDLE:-30}" open=1 json=0 want="" project="" others=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; shift 2 ;;
    --idle) idle="${2:-}"; shift 2 ;;
    --no-open) open=0; shift ;;
    --json) json=1; open=0; shift ;;
    -h|--help) sed -n '9,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "sj-view: unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$want" ] || { echo "sj-view: one project at a time ($want, $1)" >&2; exit 2; }
       want="$1"; shift ;;
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
# The address, opened on the matched project when one was asked for.
url() { jq -r --arg p "$project" '.url + (if $p == "" then "" else "#project=" + ($p | @uri) end)' "$STATE"; }

# The catalogued project (the last folder of a session's path, as the map's lanes name it) that
# best fits what was typed: the same name ignoring case and punctuation, then one that contains it
# (or is contained in it), then the likeliest by spelling. Prints the name, then on a second line
# the runners-up; nothing when none fits.
match_project() {
  sj_log_catalogue 2>/dev/null | cut -f4 | python3 -c '
import difflib, os, re, sys
want = sys.argv[1]
names = []
for line in sys.stdin:  # newest first: the order a tie is broken in
    n = os.path.basename(line.rstrip("\n").rstrip("/"))
    if n and n not in names:
        names.append(n)
key = lambda s: re.sub(r"[^0-9a-z]", "", s.lower())
w = key(want)
if not w:
    sys.exit()
close = difflib.get_close_matches(w, [key(n) for n in names], n=4, cutoff=0.6)
for tier in ([n for n in names if n.lower() == want.lower()],
             [n for n in names if key(n) == w],
             [n for n in names if key(n) and (w in key(n) or key(n) in w)],
             [n for k in close for n in names if key(n) == k]):
    if tier:
        print(tier[0]); print(", ".join(tier[1:4])); break
' "$want"
}

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
  if [ "$json" = 1 ]; then
    jq -c --arg ssh "$([ -n "${SSH_CONNECTION:-}" ] && echo "ssh -L $p:127.0.0.1:$p $(sj_host)")" \
      --arg url "$u" --arg project "$project" \
      '{running:true, url: $url, port, idle: (.idle // 30 | floor), ssh: (if $ssh == "" then null else $ssh end),
        project: (if $project == "" then null else $project end)}' "$STATE"
    return 0
  fi
  echo "scrubjay view: $u"
  if [ -n "$project" ]; then
    echo "  project: $project$([ "$project" != "$want" ] && echo " (for \"$want\")")$([ -n "$others" ] && echo "; also like it: $others")"
  elif [ -n "$want" ]; then
    echo "  no project like \"$want\" in the catalogue; showing them all"
  fi
  if [ "$i" = 0 ]; then echo "  runs until /sjview stop or the page's Stop button"
  else echo "  stops by itself after $i min unused; /sjview stop or the page's Stop button ends it now"; fi
  [ -n "${SSH_CONNECTION:-}" ] && echo "  over SSH: ssh -L $p:127.0.0.1:$p $(sj_host), then open the address above"
  return 0
}

case "$cmd" in
  status)
    if running; then report; elif [ "$json" = 1 ]; then echo '{"running":false}'; else echo "scrubjay view: not running"; fi
    exit 0 ;;
  stop)
    if running; then
      pid="$(jq -r '.pid' "$STATE")"; kill "$pid" 2>/dev/null
      for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      rm -f "$STATE"; [ "$json" = 1 ] && echo '{"running":false}' || echo "scrubjay view: stopped"
    else [ "$json" = 1 ] && echo '{"running":false}' || echo "scrubjay view: not running"; fi
    exit 0 ;;
esac

if [ -n "$want" ] && [ "$cmd" = start ]; then
  m="$(match_project)"; project="$(sed -n 1p <<<"$m")"; others="$(sed -n 2p <<<"$m")"
fi

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
[ -z "$chats" ] && [ "$json" = 0 ] && echo "  (no archive on this machine: the map shows the catalogue; transcripts are not readable here)"
report
open_url "$(url)"
exit 0
