#!/usr/bin/env bash
# SessionEnd hook — fires once when a Claude Code session ends.
#   1) append one human-readable line to <data>/logs/<host>.log  (commit + push)
#   2) relay the full transcript via ship-transcript.sh (pluggable backend)
# Never blocks the session: always exits 0.
#
# Env knobs:  DOTCLAUDE_LOG_NOGIT=1  (append log, skip its git)   CLAUDE_HOST=<name>
#             DOTCLAUDE_NOSHIP=1     (skip transcript relay)

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

# App root: this script is symlinked into ~/.claude/hooks/ but its real path is in the app repo.
self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
APP="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)" || exit 0
. "$APP/bin/lib.sh"

sid="$(printf '%s' "$input"  | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$input"  | jq -r '.cwd // empty')"
tpath="$(printf '%s' "$input"| jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0
host="$(dc_host)"
DATA="$(dc_data 2>/dev/null || true)"

# ---- 1) session line + chat index in the data repo ----
if [ -n "$DATA" ] && [ -d "$DATA" ]; then
  LOG="$DATA/logs/$host.log"; mkdir -p "$DATA/logs"; touch "$LOG"
  ts="$(date '+%Y-%m-%d %H:%M')"

  # 1a) append the human-readable session line (once per session)
  if ! grep -q "session=$sid" "$LOG" 2>/dev/null; then
    topic=""
    if [ -n "$tpath" ] && [ -f "$tpath" ]; then
      topic="$(jq -rs '[.[] | select(.type=="user") | .message.content
                         | select(type=="string")
                         | select((startswith("<") or startswith("Caveat")) | not)] | .[0] // ""' \
                "$tpath" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
    fi
    [ -n "$topic" ] || topic="(no text)"; topic="$(printf '%.100s' "$topic")"
    printf '%s | %s | %s | "%s" | session=%s\n' "$ts" "$host" "$cwd" "$topic" "$sid" >> "$LOG"
  fi

  # 1b) refresh this host's chats index (cheap, idempotent — a chat just ended)
  "$APP/bin/claude-index-chats.sh" >/dev/null 2>&1 || true

  # 1c) commit + push whatever changed (log line and/or index)
  if [ "${DOTCLAUDE_LOG_NOGIT:-0}" != "1" ]; then
    (
      cd "$DATA" || exit 0
      git add "logs/$host.log" "hosts/$host/chats.index.json" 2>/dev/null
      git diff --cached --quiet 2>/dev/null && exit 0   # nothing to commit
      git commit -q -m "chat-log + index: $host $ts" 2>/dev/null || exit 0
      if ! timeout 20 git push -q 2>/dev/null; then
        if [ -z "$(git status --porcelain 2>/dev/null \
                    | grep -vE "logs/$host.log|hosts/$host/chats.index.json")" ]; then
          timeout 20 git pull --rebase -q 2>/dev/null && timeout 20 git push -q 2>/dev/null
        fi
      fi
    ) >/dev/null 2>&1 || true
  fi
fi

# ---- 2) relay the full transcript (pluggable backend) ----
if [ "${DOTCLAUDE_NOSHIP:-0}" != "1" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
  slug="$(basename "$(dirname "$tpath")")"
  "$APP/bin/ship-transcript.sh" "$tpath" "$slug" "$sid" "$host" >/dev/null 2>&1 || true
fi

exit 0
