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

# Cross-machine memory rides its OWN git repo, self-hosted on the NAS over WireGuard — so the
# sensitive paths in auto-memory sync between machines (merge + history) without ever touching a
# third party like GitHub (which still holds only the non-sensitive config).
#   dc_memory         local working clone (Claude's per-project memory dirs symlink into it)
#   dc_memory_remote  the bare repo: a local path on the NAS box, ssh://…over-WG on clients.
#                     Empty -> memory git sync is OFF (the dir is then just machine-local).
dc_memory()        { dc_load_config; printf '%s' "${DOTCLAUDE_MEMORY:-$HOME/.dotclaude/claude-memory}"; }
dc_memory_remote() { dc_load_config; printf '%s' "${DOTCLAUDE_MEMORY_REMOTE:-}"; }

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

# Give plan files meaningful, date-prefixed names *in place*, so the relay tree (and the local
# plans/ dir) is browsable like readable/ instead of Claude Code's three-random-word names:
#   <date>_<topic>.md   (date = file mtime; topic = the plan's first markdown heading, slugified,
#   with a leading "Plan:"/"Plan -" stripped). Idempotent: files already named <YYYY-MM-DD>_… are
#   left untouched, so it can run on every ship. On a name clash with a *different* file a -N suffix
#   is added. Best-effort and silent — it must never fail the caller (the ship).
dc_normalize_plans() {  # dc_normalize_plans <plans_dir>
  local dir="$1" f base topic d target n
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*) continue ;; esac
    topic="$(grep -m1 -E '^#+[[:space:]]+' "$f" 2>/dev/null \
              | sed -E 's/^#+[[:space:]]+//; s/^[Pp]lan[[:space:]]*[:-][[:space:]]*//')"
    topic="$(printf '%s' "$topic" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-" \
              | sed -E "s/^-+//; s/-+$//" | cut -c1-50 | sed -E "s/-+$//")"
    [ -n "$topic" ] || topic="${base%.md}"
    d="$(date -r "$f" +%F 2>/dev/null || date +%F)"
    target="$dir/${d}_${topic}.md"
    if [ -e "$target" ] && [ "$target" != "$f" ]; then
      n=2; while [ -e "$dir/${d}_${topic}-${n}.md" ]; do n=$((n + 1)); done
      target="$dir/${d}_${topic}-${n}.md"
    fi
    [ "$target" = "$f" ] || mv -- "$f" "$target" 2>/dev/null || true
  done
}
