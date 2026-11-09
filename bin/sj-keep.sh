#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Keep an agent running when the terminal goes away: run it inside a named tmux session, so closing
# the SSH connection detaches it instead of hanging it up mid-turn.
#
#   usage: sj-keep.sh [--as <harness>] [--force] [--explain] -- <cmd> [args…]
#          sj-keep.sh ls                   the sj-* sessions on this machine, and how to reattach
#
# bin/sj-shell.sh routes the interactive `claude`, `opencode` and `codex` commands through here;
# anything else can be wrapped by hand (`sj-keep.sh -- pi`). With --as, only an interactive TUI
# launch of that harness is wrapped: `claude -p`, `claude --bg`, `opencode serve`, `codex exec`,
# --version, subcommands … run directly. --force wraps regardless of the arguments (a resume).
# --explain prints the decision instead of acting on it.
#
# SCRUBJAY_KEEP (env or ~/.config/scrubjay/config) says when to wrap:
#   off     never (default)
#   ssh     when this shell came in over SSH — the case that loses sessions
#   always  whenever not already inside tmux
#
# It never blocks a launch: already inside tmux, no terminal, or no tmux installed (one line on
# stderr) and the command simply runs as it would have. The session is named sj-<harness>-<folder>,
# -2, -3 … when taken: a second agent in the same folder gets its own session, never the first's.
set -uo pipefail

SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ── inside the tmux session: become the caller's environment, then run ─────────────────────────────
# Top level on purpose: sourcing `declare -x` lines inside a function would make them local.
if [ "${1:-}" = --inner ]; then
  envf="${2:-}"; shift 2; [ "${1:-}" = -- ] && shift
  if [ -f "$envf" ]; then
    # A tmux server that is already running hands a new session ITS environment, which may be days
    # old (another SSH_AUTH_SOCK, PATH, CLAUDE_CONFIG_DIR …). Replace it with the caller's, keeping
    # only what tmux itself set for this pane.
    _t="${TMUX:-}" _tp="${TMUX_PANE:-}"
    for _v in $(compgen -e); do unset "$_v" 2>/dev/null; done
    # shellcheck disable=SC1090  # written by `export -p` below, moments ago
    . "$envf" 2>/dev/null
    rm -f "$envf"
    export TMUX="$_t" TMUX_PANE="$_tp"; unset _t _tp _v
  fi
  "$@"; rc=$?
  # An agent that fails at startup would otherwise take its error message with the closing session.
  if [ "$rc" -ne 0 ]; then
    printf '\n[scrubjay] %s exited with status %d. Press Enter to close this session.\n' "$1" "$rc"
    read -r _ || true
  fi
  exit "$rc"
fi

APP="$(cd -P "$(dirname "$SELF")/.." && pwd)"
. "$APP/bin/lib.sh"
TMUX_BIN="${SJ_KEEP_TMUX:-tmux}"   # tests point this at a stub

# ── sj-keep.sh ls ─────────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = ls ]; then
  sj_has "$TMUX_BIN" || { echo "sj-keep: tmux is not installed"; exit 0; }
  rows="$("$TMUX_BIN" list-sessions -F '#{session_name}	#{?session_attached,attached,detached}	#{session_path}' 2>/dev/null | grep '^sj-')"
  [ -n "$rows" ] || { echo "no kept sessions on $(sj_host)"; exit 0; }
  printf '%s\n' "$rows" | while IFS=$'\t' read -r n a p; do printf '%-32s %-9s %s\n' "$n" "$a" "$p"; done
  echo "reattach: tmux attach -t <name>   (detach again: Ctrl-b d)"
  exit 0
fi

as="" force=0 explain=0
while [ $# -gt 0 ]; do
  case "$1" in
    --as)      as="${2:-}"; shift 2 ;;
    --force)   force=1; shift ;;
    --explain) explain=1; shift ;;
    --)        shift; break ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$SELF"; exit 0 ;;
    *)         echo "sj-keep: unknown flag '$1' (the command goes after --)" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: sj-keep.sh [--as <harness>] [--force] [--explain] -- <cmd> [args…]" >&2; exit 2; }

# interactive <harness> <args…> — 0 when this is a launch of the harness's TUI, the thing worth keeping
interactive() {
  local h="$1" a; shift
  for a in "$@"; do
    case "$a" in -h|--help|-v|-V|--version) return 1 ;; esac
  done
  case "$h" in
    claude)
      for a in "$@"; do case "$a" in -p|--print|--bg|--background) return 1 ;; esac; done
      case "${1:-}" in
        agents|attach|auth|auto-mode|config|daemon|doctor|gateway|import|install|logs|mcp|\
        migrate-installer|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade)
          return 1 ;;
      esac
      return 0 ;;
    opencode)
      # The TUI is `opencode [project] [flags]`; every other first word is a subcommand (and
      # `attach` is a client of a server that already outlives it).
      [ $# -eq 0 ] && return 0
      case "$1" in -*) return 0 ;; esac
      [ -d "$1" ] && return 0
      return 1 ;;
    codex)
      [ $# -eq 0 ] && return 0
      case "$1" in -*|resume|fork) return 0 ;; esac
      case "$1" in *" "*) return 0 ;; esac          # a prompt, not a subcommand
      return 1 ;;
    *) return 0 ;;
  esac
}

decide() {  # prints "wrap" or "direct: <why>"
  sj_load_config
  local mode="${SCRUBJAY_KEEP:-off}"
  case "$mode" in
    off|'') echo "direct: SCRUBJAY_KEEP is off"; return ;;
    ssh)    [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || { echo "direct: not an SSH session"; return; } ;;
    always) ;;
    *)      echo "direct: SCRUBJAY_KEEP='$mode' is not off|ssh|always"; return ;;
  esac
  [ -n "${TMUX:-}" ] && { echo "direct: already inside tmux"; return; }
  [ "$on_tty" = 1 ] || { echo "direct: not a terminal"; return; }
  if [ "$force" = 0 ] && [ -n "$as" ] && ! interactive "$as" "${@:2}"; then  # args, not the command
    echo "direct: not an interactive $as session"; return
  fi
  sj_has "$TMUX_BIN" || { echo "direct: tmux is not installed"; return; }
  echo wrap
}

session_name() {  # sj-<harness>-<folder>, unique among this server's sessions
  local h="${as:-$(basename "$1")}" d base n i=2
  d="$(basename "$PWD")"; [ "$PWD" = / ] && d=root
  # tmux reserves . and : in target names
  base="$(printf 'sj-%s-%s' "$h" "$d" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-48)"
  n="$base"
  while "$TMUX_BIN" has-session -t "=$n" 2>/dev/null; do n="$base-$i"; i=$((i + 1)); done
  printf '%s' "$n"
}

# Asked out here: inside $(decide) stdout is a pipe, never the terminal.
on_tty=0
if [ "${SJ_KEEP_ASSUME_TTY:-0}" = 1 ] || { [ -t 0 ] && [ -t 1 ]; }; then on_tty=1; fi
verdict="$(decide "$@")"
if [ "$explain" = 1 ]; then
  if [ "$verdict" = wrap ]; then echo "wrap $(session_name "$@")"; else echo "$verdict"; fi
  exit 0
fi

if [ "$verdict" != wrap ]; then
  [ "$verdict" = "direct: tmux is not installed" ] &&
    echo "scrubjay: SCRUBJAY_KEEP is on but tmux is not installed, so this session ends with the terminal ($(sj_install_hint tmux))" >&2
  exec "$@"
fi

name="$(session_name "$@")"
# The caller's environment, for --inner. A file, not `tmux new -e`: argv is world-readable in /proc,
# and the environment carries tokens. 0600 in the runtime dir; --inner deletes it on read.
envf="$(umask 077; mktemp "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/sj-keep.XXXXXX")" || exec "$@"
export -p > "$envf"
"$TMUX_BIN" new-session -s "$name" -c "$PWD" "$SELF" --inner "$envf" -- "$@"
# --inner deletes the file the moment it starts, so a file still here means the agent never ran:
# tmux itself failed (a dead server, an unusable socket). Never block a launch: run it here.
if [ -f "$envf" ]; then
  rm -f "$envf"
  echo "scrubjay: tmux could not start a session, so this one ends with the terminal" >&2
  exec "$@"
fi
if "$TMUX_BIN" has-session -t "=$name" 2>/dev/null; then
  echo "scrubjay: still running in tmux session '$name'. Reattach with: tmux attach -t $name" >&2
fi
exit 0
