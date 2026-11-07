#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The moves ledger: where a path went after a session recorded it. A transcript is a record, so a
# folder that moved is noted beside it rather than edited into it; the viewer shows the new path,
# a resume tells the agent, and a hand-off rewrites with it.
#
#   usage: sj-moves.sh add [--must-exist] <host> <old> <new>   record a move, publish it
#          sj-moves.sh undo <host> <old>           forget one
#          sj-moves.sh list                        TSV <host> <old> <new>, the moves in force
#          sj-moves.sh resolve <host> <path>       where <path> is now (itself when it never moved)
#          sj-moves.sh notes <host> <transcript>   what to tell an agent resuming that transcript
#
# <data>/moves/<writer>.tsv, append-only, `<epoch> <host> <old> <new>` (an empty <new> is an undo).
# One file per writing machine, like logs/, so two machines never touch the same file. <old> covers
# everything under it, and the newest line for a path wins. A later move of where something went
# carries on from the earlier one: a → b then b → c lists a → c.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
sj_load_config

die() { echo "sj-moves: $*" >&2; exit 2; }

# The moves in force. Each one carries on only through moves recorded after it, so moving a folder
# there and back again cancels out instead of looping.
moves_list() {
  local data; data="$(sj_data 2>/dev/null)" || return 0
  [ -d "$data/moves" ] || return 0
  find "$data/moves" -type f -name '*.tsv' -exec cat {} + 2>/dev/null | sort -s -t "$(printf '\t')" -k1,1n | awk -F'\t' '
    NF >= 3 { k = $2 SUBSEP $3; host[k] = $2; old[k] = $3; to[k] = $4; at[k] = NR }
    END {
      for (k in to) {
        if (to[k] == "") continue
        p = to[k]; s = at[k]
        for (step = 0; step < 32; step++) {
          best = ""; len = 0
          for (j in to) {
            if (to[j] == "" || host[j] != host[k] || at[j] <= s) continue
            o = old[j]
            if ((p == o || index(p, o "/") == 1) && length(o) > len) { best = j; len = length(o) }
          }
          if (best == "") break
          p = to[best] substr(p, len + 1); s = at[best]
        }
        if (p != old[k]) printf "%s\t%s\t%s\n", host[k], old[k], p
      }
    }' | sort
}

# Absolute, one line, no tab: a path the ledger can hold. Normal form, so `a/` and `a` are one key.
clean() {  # clean <path>
  local p="$1"
  case "$p" in /*) ;; *) die "not an absolute path: $p" ;; esac
  case "$p" in *$'\t'*|*$'\n'*|*$'\r'*) die "a path with a tab or line break cannot be recorded" ;; esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  [ "$p" != "/" ] || die "the root folder cannot move"
  printf '%s' "$p"
}

record() {  # record <host> <old> <new> <commit-message>
  local data; data="$(sj_data)" || exit 1
  mkdir -p "$data/moves" || exit 1
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$data/moves/$(sj_host).tsv" || exit 1
  sj_data_push "$4" >/dev/null 2>&1 &
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  add)
    must=0; [ "${1:-}" = --must-exist ] && { must=1; shift; }
    [ $# -eq 3 ] && [ -n "$1" ] || die "usage: sj-moves.sh add [--must-exist] <host> <old> <new>"
    case "$1" in *$'\t'*|*$'\n'*) die "not a host name: $1" ;; esac
    old="$(clean "$2")" || exit 2; new="$(clean "$3")" || exit 2
    [ "$old" != "$new" ] || die "that is the same path"
    [ "$must" = 0 ] || [ -e "$new" ] || die "$new does not exist on this machine"
    record "$1" "$old" "$new" "moved on $1: $old -> $new" ;;
  undo)
    [ $# -eq 2 ] && [ -n "$1" ] || die "usage: sj-moves.sh undo <host> <old>"
    old="$(clean "$2")" || exit 2
    record "$1" "$old" "" "move undone on $1: $old" ;;
  list)
    moves_list ;;
  resolve)
    [ $# -eq 2 ] || die "usage: sj-moves.sh resolve <host> <path>"
    moves_list | awk -F'\t' -v h="$1" -v p="$2" '
      $1 == h && (p == $2 || index(p, $2 "/") == 1) && length($2) > len { len = length($2); to = $3 }
      END { print (len ? to substr(p, len + 1) : p) }' ;;
  notes)
    [ $# -eq 2 ] || die "usage: sj-moves.sh notes <host> <transcript>"
    [ -f "$2" ] || exit 0
    said=0
    while IFS=$'\t' read -r host old new; do
      [ "$host" = "$1" ] && grep -qF -- "$old" "$2" || continue
      [ "$said" = 1 ] || echo "scrubjay: paths in this session's history have moved since. Use the new locations:"
      said=1
      printf '  %s -> %s\n' "$old" "$new"
    done < <(moves_list)
    ;;
  *) sed -n '9,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
