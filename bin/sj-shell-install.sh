#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Install (or remove) scrubjay's shell integration — the `claude resume <sid>` cross-machine resume
# in bin/sj-shell.sh — by adding ONE marked block to your shell rc. Idempotent; bin/onboard.sh
# offers it, and you can run it on an already-onboarded machine at any time.
#
#   usage: sj-shell-install.sh [--uninstall | --status] [rc-file…]
#
# With no rc files named it uses ~/.bashrc and ~/.zshrc, whichever exist — or, when neither does,
# creates the one for your login shell ($SHELL). bash and zsh only.
#
# The block sources the snippet THROUGH ~/.claude/hooks (the symlink claude-sync.sh keeps aimed at
# this app), never through this checkout's absolute path: the rc file outlives where the app happens
# to live today, and an app update then reaches the shell with no rc edit. If that symlink is ever
# missing, the guard makes the line a no-op instead of an error at every shell start.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"

BEGIN='# >>> scrubjay shell integration >>>'
END='# <<< scrubjay shell integration <<<'
# shellcheck disable=SC2016  # written verbatim into the rc file; expands THERE, at shell start
SRC='"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/../bin/sj-shell.sh"'

mode=install; rcs=()
for a in "$@"; do
  case "$a" in
    --uninstall) mode=uninstall ;;
    --status)    mode=status ;;
    -h|--help)   awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)          echo "sj-shell-install: unknown flag '$a'" >&2; exit 2 ;;
    *)           rcs+=("$a") ;;
  esac
done

if [ "${#rcs[@]}" -eq 0 ]; then
  for f in "$HOME/.bashrc" "$HOME/.zshrc"; do [ -f "$f" ] && rcs+=("$f"); done
  if [ "${#rcs[@]}" -eq 0 ] && [ "$mode" = install ]; then
    case "$(basename "${SHELL:-}")" in
      zsh)  rcs+=("$HOME/.zshrc") ;;
      bash) rcs+=("$HOME/.bashrc") ;;
      *)    echo "sj-shell-install: no ~/.bashrc or ~/.zshrc, and \$SHELL is '${SHELL:-}' (bash/zsh only)." >&2
            echo "  name the rc file to use:  sj-shell-install.sh ~/.bashrc" >&2; exit 1 ;;
    esac
  fi
fi

has_block() { [ -f "$1" ] && grep -qF "$BEGIN" "$1"; }

strip_block() {  # strip_block <rc> — rewrite in place (keeps the file's inode, perms and symlink)
  local tmp; tmp="$(mktemp)" || return 1
  awk -v b="$BEGIN" -v e="$END" '$0 == b {skip=1; next} skip && $0 == e {skip=0; next} !skip' "$1" > "$tmp" \
    && cat "$tmp" > "$1"
  rm -f "$tmp"
}

rc_status=0
for rc in "${rcs[@]}"; do
  p="$(sj_pretty_path "$rc")"
  case "$mode" in
    status)
      if has_block "$rc"; then echo "  ok    $p"; else echo "  --    $p (not installed)"; rc_status=1; fi ;;
    uninstall)
      if has_block "$rc"; then strip_block "$rc" && echo "  rm    $p"; else echo "  --    $p (was not installed)"; fi ;;
    install)
      if has_block "$rc"; then echo "  ok    $p (already installed)"; continue; fi
      {
        [ -s "$rc" ] && [ -n "$(tail -c1 "$rc")" ] && echo   # never splice onto an unterminated last line
        echo "$BEGIN"
        echo "# claude resume <sid>: resume a session recorded on any machine. Remove: sj-shell-install.sh --uninstall"
        echo "[ -f $SRC ] && . $SRC"
        echo "$END"
      } >> "$rc" && echo "  add   $p"
      ;;
  esac
done

if [ "$mode" = install ]; then
  echo "Open a new shell (or: source ~/.bashrc / ~/.zshrc) — then  claude resume <sid8>  works here."
fi
exit "$rc_status"
