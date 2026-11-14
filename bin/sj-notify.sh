#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Tell the human an agent wants them: a turn finished, or it is asking for a permission.
#
#   usage: sj-notify.sh <pid>      ring the terminal that process runs in
#          sj-notify.sh test       ring the terminal this runs in, now
#          sj-notify.sh push <sid> <idle|waiting> <pid|-> <cwd|-> <turn-seconds>
#                                  push to the phone, if nobody is looking (bin/sj-live.sh calls this)
#          sj-notify.sh test-push  send a test push now and say whether the server took it
#          sj-notify.sh health     0 when the ntfy server answers its health check (posts nothing)
#
# bin/sj-live.sh calls it when a lease goes to idle or waiting from a turn, so every harness that keeps
# a lease notifies without code of its own.
#
# The bell, with SCRUBJAY_NOTIFY=on (env or ~/.config/scrubjay/config): a BEL written to the agent's own
# terminal rather than a sound played here, since the sound has to come from where the human sits,
# which over SSH is another machine. Every layer passes a bell on — tmux (bell-action any, its
# default), SSH, and the terminal emulator, which makes the sound. nvim's :terminal passes it on only
# when 'belloff' leaves out "term"; its default "all" swallows it. No terminal (claude -p, opencode
# run): nothing.
#
# The push, with an ntfy server (SCRUBJAY_NTFY_URL, SCRUBJAY_NTFY_TOPIC, optional SCRUBJAY_NTFY_TOKEN):
# for when nobody is at any terminal. SCRUBJAY_PUSH=detached (the default once URL and topic are set)
# pushes only for an agent in a tmux session no client is attached to; always pushes whatever it runs
# in; off never. Pushed: a permission prompt (priority high), and a turn ending that lasted at least
# SCRUBJAY_PUSH_MIN_TURN seconds (300) with the start of the agent's last reply. One push per session
# per change, and the same kind again for that session within 10 minutes is dropped.
#
# The topic is a capability — whoever knows it can read and publish — so it travels in the request
# body, never on a command line, and is never printed. It never prints (but test-push) and never fails
# a hook.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEDUPE=600

bell() {  # bell <tty>
  local t="$1" dev
  case "$t" in ''|'?'|'??') [ -z "${SJ_NOTIFY_DEV:-}" ] && return 0 ;; esac
  dev="${SJ_NOTIFY_DEV:-/dev/$t}"   # tests point this at a file
  [ -w "$dev" ] || return 0
  printf '\a' >> "$dev" 2>/dev/null
}

# ---- the push ----------------------------------------------------------------------------------
push_on() {  # 0 when a server and topic are configured and SCRUBJAY_PUSH is not off
  [ -n "${SCRUBJAY_NTFY_URL:-}" ] && [ -n "${SCRUBJAY_NTFY_TOPIC:-}" ] || return 1
  case "${SCRUBJAY_PUSH:-detached}" in detached|always) return 0 ;; *) return 1 ;; esac
}

# http <get|post> <path> [body-file] — the ntfy server's answer on stdout. curl, else wget (tests
# point SJ_NOTIFY_CURL / SJ_NOTIFY_WGET at stubs). The token goes in a header file, not argv, where
# anyone on the machine could read it from ps.
http() {
  local how="$1" path="$2" body="${3:-}" url="${SCRUBJAY_NTFY_URL%/}" curl="${SJ_NOTIFY_CURL:-curl}" \
        wget="${SJ_NOTIFY_WGET:-wget}" d rc=1
  d="$(umask 077; mktemp -d 2>/dev/null)" || return 1
  if [ -n "${SCRUBJAY_NTFY_TOKEN:-}" ]; then
    printf 'Authorization: Bearer %s\n' "$SCRUBJAY_NTFY_TOKEN" > "$d/hdr"
    printf 'header = Authorization: Bearer %s\n' "$SCRUBJAY_NTFY_TOKEN" > "$d/wgetrc"
  else
    : > "$d/hdr"; : > "$d/wgetrc"
  fi
  if command -v "$curl" >/dev/null 2>&1; then
    if [ "$how" = post ]; then
      sj_timeout 15 "$curl" -fsS -m 10 -H "@$d/hdr" -H 'Content-Type: application/json' \
        --data-binary "@$body" "$url/$path" 2>/dev/null; rc=$?
    else
      sj_timeout 10 "$curl" -fsS -m 5 -H "@$d/hdr" "$url/$path" 2>/dev/null; rc=$?
    fi
  elif command -v "$wget" >/dev/null 2>&1; then
    if [ "$how" = post ]; then
      sj_timeout 15 "$wget" -q -O - -T 10 -t 1 --config="$d/wgetrc" --header='Content-Type: application/json' \
        --post-file="$body" "$url/$path" 2>/dev/null; rc=$?
    else
      sj_timeout 10 "$wget" -q -O - -T 5 -t 1 --config="$d/wgetrc" "$url/$path" 2>/dev/null; rc=$?
    fi
  fi
  rm -rf "$d"
  return "$rc"
}

# send <title> <message> <priority 1-5> <tag> — 0 when the server took it. ntfy's JSON form: the topic
# is a field of the body, POSTed to the server's root.
send() {
  local d rc
  d="$(umask 077; mktemp -d 2>/dev/null)" || return 1
  jq -nc --arg topic "$SCRUBJAY_NTFY_TOPIC" --arg title "$1" --arg message "$2" --argjson priority "$3" --arg tag "$4" \
    '{topic: $topic, title: $title, message: $message, priority: $priority, tags: [$tag]}' > "$d/body" 2>/dev/null &&
    http post "" "$d/body" >/dev/null
  rc=$?
  rm -rf "$d"
  return "$rc"
}

# The start of the agent's last reply, on one line: a question and a handoff read differently.
# Claude's transcripts only, for now. Not sj_session_last_reply: that is the tail of every reply near
# the end, for a summary, where this wants the head of the last one.
excerpt() {  # excerpt <sid> <cwd>
  [ "$(sj_harness)" = claude ] || return 0
  local t r
  sj_load_adapter claude 2>/dev/null || return 0
  t="$(sjh_find_live_transcript "$2" "$1" 2>/dev/null)" || return 0
  r="$(tail -n 300 "$t" 2>/dev/null | jq -rs '[.[] | select(.type? == "assistant")
        | [.message.content[]? | select(.type? == "text") | .text] | join(" ") | select(. != "")] | last // empty' 2>/dev/null |
       tr -s ' \t\r\n' ' ' | sed 's/^ //; s/ $//')"
  [ "${#r}" -gt 200 ] && r="${r:0:200}…"
  printf '%s' "$r"
}

push() {  # push <sid> <state> <pid|-> <cwd|-> <turn-seconds>
  local sid="$1" state="$2" pid="$3" cwd="$4" turn="${5:-0}" mode line session="" attached=0 kind prio tag \
        min dir lts now title body proj how short
  push_on || return 0
  mode="${SCRUBJAY_PUSH:-detached}"
  [ "$pid" = - ] && pid=""; [ "$cwd" = - ] && cwd=""
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  case "$turn" in ''|*[!0-9]*) turn=0 ;; esac
  if [ -n "$pid" ] && line="$(sj_tmux_pane_of "$pid")"; then
    IFS=$'\t' read -r _ _ session attached <<<"$line"
    [ "$attached" -gt 0 ] 2>/dev/null && attached=1 || attached=0
  fi
  # Someone is looking (or could be, outside tmux): the bell is enough.
  [ "$mode" = always ] || { [ -n "$session" ] && [ "$attached" = 0 ]; } || return 0
  min="${SCRUBJAY_PUSH_MIN_TURN:-300}"; case "$min" in ''|*[!0-9]*) min=300 ;; esac
  case "$state" in
    waiting) kind=waiting; prio=4; tag=lock ;;
    idle)    [ "$turn" -ge "$min" ] || return 0; kind=finished; prio=3; tag=hourglass_flowing_sand ;;
    *) return 0 ;;
  esac
  # Once per session and kind within DEDUPE seconds. Claimed before the post, so a second hook racing
  # this one finds the claim.
  dir="$(sj_progress_dir)/notify"; mkdir -p "$dir" 2>/dev/null || return 0
  now="$(date +%s)"
  lts="$(cat "$dir/$sid.$kind.push" 2>/dev/null)"
  case "$lts" in ''|*[!0-9]*) lts=0 ;; esac
  [ $((now - lts)) -lt "$DEDUPE" ] && return 0
  printf '%s\n' "$now" > "$dir/$sid.$kind.push"
  find "$dir" -name '*.push' -mtime +7 -exec rm -f {} + 2>/dev/null

  short="${sid:0:8}"
  proj="$(basename "${cwd:-?}")"
  # The front door's own way back, once there is one (bin/sj.sh); tmux's otherwise.
  if [ -z "$session" ]; then how="not in tmux (pid ${pid:-?})"
  elif [ -f "$APP/bin/sj.sh" ] && grep -q 'attach' "$APP/bin/sj.sh" 2>/dev/null; then how="sj attach ${sid:0:8}"
  else how="tmux attach -t $session"; fi
  if [ "$kind" = waiting ]; then
    title="$proj on $(sj_host): waiting for a permission"
    body="An agent stopped at a permission prompt."
  else
    if [ "$turn" -ge 60 ]; then title="$proj on $(sj_host): your turn ($((turn / 60)) min of work)"
    else title="$proj on $(sj_host): your turn (${turn} s of work)"; fi
    sleep "${SJ_NOTIFY_SETTLE:-1}"   # the Stop hook can run a moment before the reply is on disk
    body="$(excerpt "$sid" "$cwd")"; [ -n "$body" ] || body="The agent finished a turn."
  fi
  body="$body
folder: $(sj_pretty_path "${cwd:-?}")
session: $short${session:+ · tmux $session}
attach: $how"
  if send "$title" "$body" "$prio" "$tag"; then
    printf '%s ok %s %s\n' "$now" "$kind" "$short" > "$dir/last"
  else
    printf '%s fail %s %s\n' "$now" "$kind" "$short" > "$dir/last"
  fi
  return 0
}

case "${1:-}" in
  test) bell "$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')" ;;
  push)
    shift; . "$APP/bin/lib.sh"; sj_load_config
    push "$@" >/dev/null 2>&1 ;;
  test-push|health)
    . "$APP/bin/lib.sh"; sj_load_config
    if [ -z "${SCRUBJAY_NTFY_URL:-}" ] || [ -z "${SCRUBJAY_NTFY_TOPIC:-}" ]; then
      echo "sj-notify: no push server — set SCRUBJAY_NTFY_URL and SCRUBJAY_NTFY_TOPIC in ~/.config/scrubjay/config" >&2
      exit 1
    fi
    if [ "$1" = health ]; then
      case "$(http get v1/health)" in *'"healthy":true'*) exit 0 ;; *) exit 1 ;; esac
    fi
    if send "scrubjay test from $(sj_host)" "A test push from sj-notify.sh test-push. Agents waiting for you will look like this." 3 bell
    then echo "sj-notify: test push sent to ${SCRUBJAY_NTFY_URL%/} (topic hidden)"
    else echo "sj-notify: the push server at ${SCRUBJAY_NTFY_URL%/} did not take the test push" >&2; exit 1; fi ;;
  ''|*[!0-9]*) ;;
  *) bell "$(ps -o tty= -p "$1" 2>/dev/null | tr -d ' ')" ;;
esac
exit 0
