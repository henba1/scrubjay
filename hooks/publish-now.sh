#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Manual "publish now" — runs the SessionEnd actions on demand (the /sjlog command) WITHOUT ending
# the session: log line + chats index + data-repo push + memory push + transcript/plans/history/tasks
# relay. The SessionEnd hook is normally fed a JSON payload by Claude; here we reconstruct it by
# asking the harness adapter for the in-progress session's transcript (sjh_find_live_transcript).
# Idempotent and best-effort: safe to run repeatedly, and SessionEnd will still fire normally later.
set -uo pipefail

# App root — `cd -P` so a symlinked ~/.claude/hooks resolves to the real app repo. See the longer
# note in hooks/sync-session.sh for why this is not `readlink -f`.
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "publish-now: jq required" >&2; exit 0; }

sj_load_adapter "$(sj_harness)" || exit 0
cwd="$PWD"
tpath="$(sjh_find_live_transcript "$cwd")"
[ -n "$tpath" ] && [ -f "$tpath" ] || { echo "publish-now: no transcript found for $cwd" >&2; exit 0; }
f="$(basename "$tpath")"; sid="${f%.*}"

# Feed log-session.sh the same shape Claude would, and run it synchronously (--detached skips its
# self-relaunch), so the step report below reflects a completed publish.
sj_progress_begin publish "${sid:0:8}"
printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s"}' "$sid" "$cwd" "$tpath" \
  | bash "$APP/hooks/log-session.sh" --detached

sj_progress_end
sj_progress_render
exit 0
