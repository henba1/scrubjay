#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Tell the human an agent wants them: a turn finished, or it is asking for a permission.
#
#   usage: sj-notify.sh <pid>      ring the terminal that process runs in
#          sj-notify.sh test       ring the terminal this runs in, now
#
# bin/sj-live.sh calls it when a lease goes to idle or waiting from a turn, with SCRUBJAY_NOTIFY=on
# (env or ~/.config/scrubjay/config), so every harness that keeps a lease rings without code of its own.
#
# It writes a bell (BEL) to the agent's own terminal rather than playing a sound here: the sound has to
# come from where the human sits, which over SSH is another machine. Every layer passes a bell on —
# tmux (bell-action any, its default), SSH, and the terminal emulator, which makes the sound. nvim's
# :terminal passes it on only when 'belloff' leaves out "term"; its default "all" swallows it.
# No terminal (claude -p, opencode run): nothing. It never prints and never fails.
set -uo pipefail

case "${1:-}" in
  test) t="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')" ;;
  ''|*[!0-9]*) exit 0 ;;
  *) t="$(ps -o tty= -p "$1" 2>/dev/null | tr -d ' ')" ;;
esac
case "$t" in ''|'?'|'??') [ -z "${SJ_NOTIFY_DEV:-}" ] && exit 0 ;; esac
dev="${SJ_NOTIFY_DEV:-/dev/$t}"   # tests point this at a file
[ -w "$dev" ] || exit 0
printf '\a' >> "$dev" 2>/dev/null
exit 0
