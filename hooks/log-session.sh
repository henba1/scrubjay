#!/usr/bin/env bash
# Stop hook — append ONE human-readable line per Claude Code session to
# logs/<host>.log:  timestamp | host | cwd | "first-user-prompt topic" | session=<id>
# Dedupes per session (writes once), then commits + pushes just that log file.
# Never blocks the session: always exits 0; git work is isolated to the log file.
#
# Env knobs:
#   DOTCLAUDE_LOG_NOGIT=1   append only, skip commit/push (used for testing)
#   CLAUDE_HOST=<name>      override host name

input="$(cat)"   # Claude Code sends event JSON on stdin

command -v jq >/dev/null 2>&1 || exit 0

# Repo root: this script is symlinked into ~/.claude/hooks/ but its real path is in the repo.
self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
REPO="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)" || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
tpath="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0

# Stable host name (same resolution as the other scripts).
if   [ -n "${CLAUDE_HOST:-}" ];                then host="$CLAUDE_HOST"
elif [ -f "$HOME/.config/dotclaude/host" ];    then host="$(cat "$HOME/.config/dotclaude/host")"
else                                                host="$(hostname -s)"; fi

LOG="$REPO/logs/$host.log"
mkdir -p "$REPO/logs"; touch "$LOG"

# One entry per session.
grep -q "session=$sid" "$LOG" 2>/dev/null && exit 0

# Topic = first real textual user message (skip command/caveat wrappers), single line, truncated.
topic=""
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  topic="$(jq -rs '[.[] | select(.type=="user") | .message.content
                     | select(type=="string")
                     | select((startswith("<") or startswith("Caveat")) | not)] | .[0] // ""' \
            "$tpath" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
fi
[ -n "$topic" ] || topic="(no text)"
topic="$(printf '%.100s' "$topic")"

ts="$(date '+%Y-%m-%d %H:%M')"
printf '%s | %s | %s | "%s" | session=%s\n' "$ts" "$host" "$cwd" "$topic" "$sid" >> "$LOG"

[ "${DOTCLAUDE_LOG_NOGIT:-0}" = "1" ] && exit 0

# Commit + push ONLY this log file. Pathspec commit ignores any other staged/working
# changes, so we never disturb in-progress work. All best-effort; never fail the hook.
(
  cd "$REPO" || exit 0
  git add "logs/$host.log" 2>/dev/null            # stage (needed for a host's first entry)
  git commit -q -m "chat-log: $host $ts" -- "logs/$host.log" 2>/dev/null || exit 0
  if ! timeout 20 git push -q 2>/dev/null; then
    # Remote may be ahead — only rebase+retry if the rest of the tree is clean.
    if [ -z "$(git status --porcelain 2>/dev/null | grep -v "logs/$host.log")" ]; then
      timeout 20 git pull --rebase -q 2>/dev/null && timeout 20 git push -q 2>/dev/null
    fi
  fi
) >/dev/null 2>&1 || true

exit 0
