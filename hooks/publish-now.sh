#!/usr/bin/env bash
# Manual "publish now" — runs the SessionEnd actions on demand (the /dclog command) WITHOUT ending
# the session: log line + chats index + data-repo push + memory push + transcript/plans/history/tasks
# relay. The SessionEnd hook is normally fed a JSON payload by Claude; here we reconstruct it by
# finding this session's transcript (the newest .jsonl that records the current working dir).
# Idempotent and best-effort: safe to run repeatedly, and SessionEnd will still fire normally later.
set -uo pipefail

self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
APP="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "publish-now: jq required" >&2; exit 0; }

proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
cwd="$PWD"
# Prefer the newest transcript that records THIS working dir; fall back to the newest overall.
tpath="$(grep -lF "\"cwd\":\"$cwd\"" "$proj"/*/*.jsonl 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)"
[ -n "$tpath" ] || tpath="$(ls -t "$proj"/*/*.jsonl 2>/dev/null | head -1)"
[ -n "$tpath" ] && [ -f "$tpath" ] || { echo "publish-now: no transcript found for $cwd" >&2; exit 0; }
sid="$(basename "$tpath" .jsonl)"

# Feed log-session.sh the same shape Claude would, and run it synchronously (--detached skips its
# self-relaunch), so the status line below reflects a completed publish.
printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s"}' "$sid" "$cwd" "$tpath" \
  | bash "$APP/hooks/log-session.sh" --detached

echo "published session ${sid:0:8} (cwd $cwd)"
M="$(dc_memory)"; [ -d "$M/.git" ] && echo "memory @ $(git -C "$M" log --oneline -1 2>/dev/null || echo '(no commits)')"
exit 0
