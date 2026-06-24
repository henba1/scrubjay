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

# Human-readable relpath for a transcript, under the per-host `readable/` tree:
#   <project>/<date>_<topic>__<sid8>   (project = basename of the session cwd; topic = first
#   real user prompt, slugified). Derived from the .jsonl itself so it also works for backfill.
dc_readable_relpath() {  # dc_readable_relpath <transcript.jsonl> <session_id>
  local src="$1" sid="$2" cwd project topic d
  if ! command -v jq >/dev/null 2>&1; then printf 'misc/%s' "${sid:0:8}"; return; fi
  cwd="$(jq -rs '[ .[] | select(.cwd!=null) | .cwd ][0] // ""' "$src" 2>/dev/null)"
  project="$(basename "${cwd:-misc}")"; [ -n "$project" ] && [ "$project" != "/" ] || project="misc"
  topic="$(jq -rs '[ .[] | select(.type=="user") | .message.content
                    | select(type=="string")
                    | select((startswith("<") or startswith("Caveat"))|not) ][0] // ""' "$src" 2>/dev/null)"
  topic="$(printf '%s' "$topic" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-" \
            | sed -E "s/^-+//; s/-+$//" | cut -c1-40 | sed -E "s/-+$//")"
  [ -n "$topic" ] || topic="session"
  d="$(date -r "$src" +%F 2>/dev/null || date +%F)"
  printf '%s/%s_%s__%s' "$project" "$d" "$topic" "${sid:0:8}"
}
