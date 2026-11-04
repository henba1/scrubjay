# shellcheck shell=bash  # sourced by bash AND zsh; written to the subset both share
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Shell integration — SOURCE this from ~/.bashrc / ~/.zshrc; do not execute it. bash and zsh.
# bin/sj-shell-install.sh writes the one line that does so, pointing through ~/.claude/hooks (the
# symlink claude-sync.sh keeps aimed at this app), so an app update reaches every machine with no
# rc edit.
#
# It defines a `claude` function that adds ONE thing to the real binary:
#
#     claude resume <sid>        claude --resume <sid>        claude -r <sid>
#
# resume a session even when it was recorded on ANOTHER machine — bin/sj-claude-resume.sh fetches it
# from the scrubjay archive into this machine's ~/.claude/projects/ (the /sjresume hand-off) and then
# runs the real `claude --resume <full-sid>`. <sid> may be the 8-hex handle or a full id.
#
# Every other invocation goes straight to the binary: the only work done first is one pattern match
# on the argument string, so there is no startup cost to speak of. Only an argument that LOOKS like
# a session id (8–36 hex digits and dashes) is intercepted — `claude --resume` with no value (the
# picker), `--resume <search words>` and `--resume <session name>` are all passed through untouched.
# `resume` is only special as the first word: `claude "resume the build"` is still a prompt.

_sj_is_sid() {  # _sj_is_sid <arg> — 0 when it looks like a session id or an 8+ hex prefix of one
  case "$1" in *[!0-9a-fA-F-]*|'') return 1 ;; esac
  [ "${#1}" -ge 8 ] && [ "${#1}" -le 36 ]
}

function claude {
  # fast path: nothing that could be a resume — hand over before doing anything else
  case " $* " in
    *" resume "*|*" -r "*|*" --resume "*|*" --resume="*) ;;
    *) command claude "$@"; return ;;
  esac

  local sid="" flag="" a
  local -a rest
  rest=()
  if [ "$1" = resume ]; then
    if [ $# -ge 2 ] && _sj_is_sid "$2"; then sid="$2"; shift 2; rest=("$@"); fi
  else
    for a in "$@"; do
      if [ -n "$flag" ]; then                       # the value after -r / --resume
        if [ -z "$sid" ] && _sj_is_sid "$a"; then sid="$a"; flag=""; continue; fi
        rest+=("$flag"); flag=""
      fi
      case "$a" in
        -r|--resume) [ -z "$sid" ] && { flag="$a"; continue; } ;;
        --resume=*)  if [ -z "$sid" ] && _sj_is_sid "${a#--resume=}"; then sid="${a#--resume=}"; continue; fi ;;
      esac
      rest+=("$a")
    done
    [ -n "$flag" ] && rest+=("$flag")
  fi

  if [ -z "$sid" ]; then command claude "$@"; return; fi
  bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/../bin/sj-claude-resume.sh" "$sid" "${rest[@]}"
}
