#!/usr/bin/env bash
# Shared helpers for the dotclaude app. Source this; do not execute.
# The app (logic) is this repo; personal content lives in a separate data repo, and
# transcripts in a separate relay repo. Pointers come from ~/.config/dotclaude/config.

dc_load_config() {
  [ -f "$HOME/.config/dotclaude/config" ] && . "$HOME/.config/dotclaude/config"
  : "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
}

# Stable host name — NOT `hostname -s` (transient on HPC login nodes).
dc_host() {
  if   [ -n "${CLAUDE_HOST:-}" ];             then printf '%s' "$CLAUDE_HOST"
  elif [ -f "$HOME/.config/dotclaude/host" ]; then cat "$HOME/.config/dotclaude/host"
  else                                             hostname -s; fi
}

# Path to the data repo (required).
dc_data() {
  dc_load_config
  if [ -z "${DOTCLAUDE_DATA:-}" ]; then
    echo "dotclaude: DOTCLAUDE_DATA not set — see ~/.config/dotclaude/config" >&2
    return 1
  fi
  printf '%s' "$DOTCLAUDE_DATA"
}

# Path to the transcripts relay repo (optional; empty if transcript sync is off).
dc_chats() { dc_load_config; printf '%s' "${DOTCLAUDE_CHATS:-}"; }
