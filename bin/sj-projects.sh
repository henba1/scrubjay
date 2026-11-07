#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The project links: which projects are one project, and from when. A folder's name is all the
# catalogue knows, so a rename, a merge or a subfolder reads as separate projects until someone says
# otherwise. Noted beside the catalogue, never edited into it, so every link can be undone.
#
#   usage: sj-projects.sh add <from> <into> [<date>]   <from> flows into <into> on YYYY-MM-DD; no date: always did
#          sj-projects.sh undo <from>                  forget where <from> flows
#          sj-projects.sh list                         TSV <from> <into> <date>, the links in force
#
# <data>/projects/<writer>.tsv, append-only, `<epoch> <from> <into> <date>` (an empty <into> is an
# undo). One file per writing machine, like logs/, so two machines never touch the same file. A
# project flows into one other, and the newest line for it wins.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
sj_load_config

die() { echo "sj-projects: $*" >&2; exit 2; }

links_list() {
  local data; data="$(sj_data 2>/dev/null)" || return 0
  [ -d "$data/projects" ] || return 0
  find "$data/projects" -type f -name '*.tsv' -exec cat {} + 2>/dev/null | sort -s -t "$(printf '\t')" -k1,1n | awk -F'\t' '
    NF >= 3 { to[$2] = $3; at[$2] = $4 }
    END { for (k in to) if (to[k] != "") printf "%s\t%s\t%s\n", k, to[k], at[k] }' | sort
}

name_ok() {  # name_ok <name>
  [ -n "$1" ] || die "a project needs a name"
  case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) die "a name with a tab or line break cannot be recorded" ;; esac
}

record() {  # record <from> <into> <date> <commit-message>
  local data; data="$(sj_data)" || exit 1
  mkdir -p "$data/projects" || exit 1
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$data/projects/$(sj_host).tsv" || exit 1
  sj_data_push "$4" >/dev/null 2>&1 &
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  add)
    [ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: sj-projects.sh add <from> <into> [<date>]"
    from="$1"; into="$2"; at="${3:-}"
    name_ok "$from"; name_ok "$into"
    [ "$from" != "$into" ] || die "a project cannot flow into itself"
    case "$at" in ''|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) die "not a date: $at" ;; esac
    # Walking on from <into> must not come back to <from>. Its own old link is about to be replaced.
    all="$(links_list)"; p="$into"
    for _ in $(seq 1 64); do
      p="$(printf '%s\n' "$all" | awk -F'\t' -v k="$p" '$1 == k { print $2; exit }')"
      [ -n "$p" ] || break
      [ "$p" != "$from" ] || die "$into already flows into $from"
    done
    record "$from" "$into" "$at" "project: $from flows into $into${at:+ on $at}" ;;
  undo)
    [ $# -eq 1 ] || die "usage: sj-projects.sh undo <from>"
    name_ok "$1"
    record "$1" "" "" "project link undone: $1" ;;
  list)
    links_list ;;
  *) sed -n '9,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
