#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The tmux status bar for agent sessions: what this pane's agent is doing, and the other sessions of
# the same project. tmux/scrubjay.conf draws the bar from here and opens the menu on a click.
#
#   usage: sj-status.sh left <tmux-session> <pane-id> [<cols> [<pane-title>]]
#                                                       this session: project ⎇ branch · sid · state
#                                                       age, then the project's other sessions
#          sj-status.sh right [<pane-title>] [<cols>]   the session's title · time · date · host
#                                                       (<cols>: the client's width - both fit in it)
#          sj-status.sh menu <client> <tmux-session> <pane-id> [<x>]
#                                                       a tmux menu of the project's sessions; choosing
#                                                       one that runs in tmux switches to its pane
#          sj-status.sh list [<tmux-session> <pane-id>] TSV, one session a line: this|related|other
#                                                       <harness> <sid> <state> <age-s> <project>
#                                                       <branch> <where>
#
# The sessions are bin/sj-live.sh's (every harness's own registry), the waiting state its leases'
# (a permission prompt). A session's project is its git repository, worktrees included, so a
# session in a subfolder or another worktree of the repo is the same project; outside git it is the
# folder. Where it runs comes from its process: a tmux pane (sj-claude-x:0.%3, which the menu can
# switch to), GreyKnight's agent pane (gk) or another Neovim's (nvim), else nothing.
#
# Made for an OLED screen: black, dim, nothing static. The text drifts a cell every 2 minutes (0-5
# cells) and its grey breathes a step a minute. SCRUBJAY_STATUS_DRIFT=off keeps it still;
# SCRUBJAY_STATUS_MAX (default 3) is how many related sessions the bar names before +n.
#
# Tests: SJ_STATUS_TMUX names the tmux binary, SJ_STATUS_NOW the time, SJ_STATUS_TTL=0 skips the cache.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
sj_load_config
TMUX_BIN="${SJ_STATUS_TMUX:-tmux}"
NOW="${SJ_STATUS_NOW:-$(date +%s)}"
MAX="${SCRUBJAY_STATUS_MAX:-3}"

# ── the look ──────────────────────────────────────────────────────────────────────────────────────
GREYS=("#3a3d42" "#44474d" "#4e5258" "#585c63" "#4e5258" "#44474d")
if [ "${SCRUBJAY_STATUS_DRIFT:-on}" = off ]; then drift=0 fg="${GREYS[2]}"
else drift=$(( (NOW / 120) % 6 )) fg="${GREYS[$(( (NOW / 60) % 6 ))]}"; fi
DIM="#2a2c30"
SEP="#[fg=$DIM] · #[fg=$fg]"
pad() { printf '%*s' "$1" ''; }

# working: a muted amber ●; waiting for you (a permission prompt): brighter, ◐ - the one to notice;
# idle: a muted green ○. A shape each, so they are told apart without the colour.
glyph() {
  case "$1" in
    working) printf '#[fg=#8a6d3b]●#[fg=%s]' "$fg" ;;
    waiting) printf '#[fg=#c9a227]◐#[fg=%s]' "$fg" ;;
    *)       printf '#[fg=#4f7a5a]○#[fg=%s]' "$fg" ;;
  esac
}
plain_glyph() { case "$1" in working) printf '●' ;; waiting) printf '◐' ;; *) printf '○' ;; esac; }
age() {  # seconds -> 40s, 12m, 3h, 2d
  local s="$1"
  if   [ "$s" -lt 60 ];    then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%sm' $(( s / 60 ))
  elif [ "$s" -lt 86400 ]; then printf '%sh' $(( s / 3600 ))
  else                          printf '%sd' $(( s / 86400 )); fi
}

# ── where a session runs ─────────────────────────────────────────────────────────────────────────
declare -A PANE  # pane pid -> session:window.pane_id
while IFS=$'\t' read -r ppid target; do [ -n "$ppid" ] && PANE[$ppid]="$target"
done < <("$TMUX_BIN" list-panes -a -F '#{pane_pid}	#{session_name}:#{window_index}.#{pane_id}' 2>/dev/null)

where() {  # <pid> -> tmux:<target> | gk | nvim | -
  local p="$1" up comm
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -n "${PANE[$p]:-}" ] && { printf 'tmux:%s' "${PANE[$p]}"; return; }
    read -r up comm < <(ps -o ppid=,comm= -p "$p" 2>/dev/null) || break
    case "${comm##*/}" in
      nvim)
        # GreyKnight is Neovim under NVIM_APPNAME=greyknight (its `gk` alias)
        if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx 'NVIM_APPNAME=greyknight'; then printf 'gk'
        else printf 'nvim'; fi
        return ;;
    esac
    [ "${up:-0}" -gt 1 ] 2>/dev/null || break
    p="$up"
  done
  printf -- '-'
}

# ── a session's project: its git repository (worktrees are one), else its folder ─────────────────
declare -A PKEY PNAME PBRANCH
project() {  # <cwd> -> fills PKEY/PNAME/PBRANCH[cwd]
  local cwd="$1" common
  [ -n "${PKEY[$cwd]+x}" ] && return
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common" ]; then
    PKEY[$cwd]="$common"
    case "$common" in */.git) PNAME[$cwd]="$(basename "$(dirname "$common")")" ;;
                      *)      PNAME[$cwd]="$(basename "${common%.git}")" ;; esac
    PBRANCH[$cwd]="$(git -C "$cwd" branch --show-current 2>/dev/null)"
    [ -n "${PBRANCH[$cwd]}" ] || PBRANCH[$cwd]="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
  else
    PKEY[$cwd]="$cwd" PNAME[$cwd]="$(basename "$cwd")" PBRANCH[$cwd]=""
  fi
}

# ── every live session ─────────────────────────────────────────────────────────────────────────
# collect: harness sid state since project branch where project-key - the costly part (every harness's
# registry, the leases, git, the process tree), so the bar reads it from a cache for SJ_STATUS_TTL
# seconds (default 8: one tmux refresh of 10 s); the menu always collects anew.
collect() {
  local h sid pid st ts cwd lease lst lts
  while IFS=$'\t' read -r h sid pid st ts cwd; do
    if [ -z "$sid" ] || [ "$st" = ended ]; then continue; fi
    # a permission prompt is the lease's to know (the harness's registry says busy or idle)
    lease="$(sj_progress_dir)/live/$sid.lease"
    if [ -f "$lease" ]; then
      IFS=$'\t' read -r lst lts < <(jq -r '[.state // "", .ts // 0] | @tsv' "$lease" 2>/dev/null)
      [ "${lst:-}" = waiting ] && [ "${lts:-0}" -ge "${ts:-0}" ] && st=waiting ts="$lts"
    fi
    project "$cwd"
    # no branch (outside git) is "-": read folds an empty field between tabs into the next
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$sid" "$st" "${ts:-$NOW}" "${PNAME[$cwd]}" \
      "${PBRANCH[$cwd]:--}" "$(where "$pid")" "${PKEY[$cwd]}"
  done < <(bash "$APP/bin/sj-live.sh" sessions 2>/dev/null)
}

CACHE="$(sj_progress_dir)/status.tsv"
sessions() {  # [fresh]
  local ttl="${SJ_STATUS_TTL:-8}" mtime
  if [ "${1:-}" != fresh ] && [ "$ttl" -gt 0 ] && [ -f "$CACHE" ]; then
    mtime="$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)"
    [ $(( $(date +%s) - mtime )) -lt "$ttl" ] && { cat "$CACHE"; return; }
  fi
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null
  local tmp="$CACHE.$$"
  collect > "$tmp" 2>/dev/null
  if mv -f "$tmp" "$CACHE" 2>/dev/null; then cat "$CACHE"; else cat "$tmp" 2>/dev/null; rm -f "$tmp"; fi
}

# list <tmux-session> <pane-id> [fresh]: this|related|other harness sid state age project branch where
list() {
  local tsess="${1:-}" tpane="${2:-}" mine="" key="" rows=() h sid st ts name branch w k row
  while IFS=$'\t' read -r h sid st ts name branch w k; do
    row="$h	$sid	$st	$(( NOW - ts < 0 ? 0 : NOW - ts ))	$name	$branch	$w"
    # this pane's: its tmux target is <this session>:<window>.<this pane>
    if [ -z "$mine" ] && [ -n "$tpane" ] && [ "${w#tmux:"$tsess":}" != "$w" ] && [ "${w##*.}" = "$tpane" ]; then
      mine="$row" key="$k"
    else
      rows+=("$k	$row")
    fi
  done < <(sessions "${3:-}")
  [ -n "$mine" ] && printf 'this\t%s\n' "$mine"
  for row in "${rows[@]}"; do
    k="${row%%	*}"
    if [ -n "$key" ] && [ "$k" = "$key" ]; then printf 'related\t%s\n' "${row#*	}"
    else printf 'other\t%s\n' "${row#*	}"; fi
  done | sort -t$'\t' -k1,1r -k5,5n   # related first, the most recent first
}

esc() { printf '%s' "${1//#/##}"; }  # tmux formats: a # of the text is ##

vislen() { local t; t="$(printf '%s' "$1" | sed 's/#\[[^]]*\]//g')"; printf '%s' "${#t}"; }

# The right part at width <cols>: title · time · date · host; narrower than 120 columns, the title (a
# quarter of the width at most) and the time only. The left part leaves exactly its room.
right_str() {  # <pane-title> <cols>
  local cols="$2" title cap out
  title="$(printf '%s' "$1" | sed -E 's/^[^[:alnum:]]+ *//')"  # the spinner in front of the title
  [ "$title" = "$(hostname)" ] && title=""                       # a pane nothing titled
  cap=48; [ "$cols" -lt 120 ] && cap=$(( cols / 4 ))
  [ ${#title} -gt "$cap" ] && title="${title:0:$(( cap > 1 ? cap - 1 : 0 ))}…"
  [ "$cap" -lt 4 ] && title=""
  out="#[fg=$fg]"
  [ -n "$title" ] && out+="$(esc "$title")$SEP"
  out+="$(date -d "@$NOW" '+%H:%M' 2>/dev/null || date '+%H:%M')"
  [ "$cols" -ge 120 ] && out+="$SEP$(date -d "@$NOW" '+%a %-d %b' 2>/dev/null || date '+%a %e %b')$SEP$(sj_host)"
  printf '%s' "$out$(pad $(( 5 - drift )))"
}

case "${1:-}" in
  left)
    tsess="${2:-}" tpane="${3:-}" cols="${4:-200}"
    budget=$(( cols - $(vislen "$(right_str "${5:-}" "$cols")") - 3 ))
    mine=0 related=() mybranch=""
    while IFS=$'\t' read -r kind h sid st a name branch w; do
      [ "$branch" = - ] && branch=""
      case "$kind" in
        this)
          mine=1 mybranch="$branch" myname="$name" mysid="${sid:0:8}" myst="$st" mya="$(age "$a")" ;;
        related)
          item="$(glyph "$st") ${sid:0:8}"
          [ -n "$branch" ] && [ "$branch" != "$mybranch" ] && item+=" $(esc "$branch")"
          case "$w" in gk|nvim) item+=" #[fg=$DIM]$w#[fg=$fg]" ;; esac
          related+=("$item $(age "$a")") ;;
      esac
    done < <(list "$tsess" "$tpane")
    if [ "$mine" = 0 ]; then printf '%s' "$(pad "$drift")#[fg=$fg]$(sj_host)$SEP$(esc "$tsess")"; exit 0; fi
    # this session in full, then shorter until it fits: fewer related sessions named (the rest +n),
    # then no session id, then no branch
    build() {  # <related shown> <with sid> <with branch>
      local out k=0 item
      out="$(pad "$drift")#[fg=$fg]$(esc "$myname")"
      [ "$3" = 1 ] && [ -n "$mybranch" ] && out+=" #[fg=$DIM]⎇#[fg=$fg] $(esc "$mybranch")"
      [ "$2" = 1 ] && out+="$SEP$mysid"
      out+="$SEP$(glyph "$myst") $myst $mya"
      if [ ${#related[@]} -gt 0 ]; then
        out+="#[fg=$DIM]   ┊  #[fg=$fg]"
        for item in "${related[@]}"; do
          [ "$k" -ge "$1" ] && break
          [ "$k" -gt 0 ] && out+="$SEP"; out+="$item"; k=$((k + 1))
        done
        [ ${#related[@]} -gt "$1" ] && { [ "$1" -gt 0 ] && out+="$SEP"; out+="+$(( ${#related[@]} - $1 ))"; }
      fi
      printf '%s' "$out"
    }
    shown=$(( ${#related[@]} < MAX ? ${#related[@]} : MAX ))
    for n in $(seq "$shown" -1 0); do
      out="$(build "$n" 1 1)"; [ "$(vislen "$out")" -le "$budget" ] && { printf '%s' "$out"; exit 0; }
    done
    out="$(build 0 0 1)"; [ "$(vislen "$out")" -le "$budget" ] && { printf '%s' "$out"; exit 0; }
    printf '%s' "$(build 0 0 0)" ;;

  right) right_str "${2:-}" "${3:-200}" ;;

  menu)
    client="${2:-}" tsess="${3:-}" tpane="${4:-}" x="${5:-0}"
    items=() n=0 title="" mybranch=""
    while IFS=$'\t' read -r kind h sid st a name branch w; do
      [ "$kind" = other ] && continue
      [ "$branch" = - ] && branch=""
      [ "$kind" = this ] && { title="$name"; mybranch="$branch"; }
      label="$(plain_glyph "$st") ${sid:0:8}  $st $(age "$a")"
      [ -n "$branch" ] && label+="  ⎇ $branch"
      case "$w" in tmux:*) label+="  ${w#tmux:}" ;; -) ;; *) label+="  in $w" ;; esac
      [ "$kind" = this ] && label+="  (this one)"
      label="$(esc "$label")"
      n=$((n + 1)); keyc=""; [ "$n" -le 9 ] && keyc="$n"
      if [ "$kind" = this ] || [ "${w#tmux:}" = "$w" ]; then
        items+=("-$label" "" "")   # disabled: here already, or not in a tmux pane
      else
        t="${w#tmux:}"
        items+=("$label" "$keyc" "switch-client -t '${t%%:*}' ; select-window -t '${t%.*}' ; select-pane -t '${t##*.}'")
      fi
    done < <(list "$tsess" "$tpane" fresh)
    [ -n "$title" ] || title="$tsess"
    items+=("" "All tmux sessions" "s" "choose-tree -Zs")  # "": a separator, one argument
    # --: the options end here - a disabled item begins with -
    exec "$TMUX_BIN" display-menu -c "$client" -T "#[align=centre] $(esc "$title") " -x "$x" -y S -- "${items[@]}" ;;

  list) shift; list "${1:-}" "${2:-}" ;;
  *) sed -n '8,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
