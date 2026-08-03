#!/usr/bin/env bash
# SessionEnd hook — fires once when a coding session ends (any harness; see bin/adapters/).
#   1) append one human-readable line to <data>/logs/<host>.log  (commit + push)
#   2) relay the session's records via ship-transcript.sh (pluggable backend)
# Never blocks the session: always exits 0.
#
# Env knobs:  SCRUBJAY_LOG_NOGIT=1  (append log, skip its git)   CLAUDE_HOST=<name>
#             SCRUBJAY_NOSHIP=1     (skip transcript relay)

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

# SessionEnd fires during shutdown; Claude cancels hooks that haven't returned by the time the
# session process goes away (-> "Hook cancelled", killing the network-bound git+relay mid-run).
# So on first entry, re-launch ourselves DETACHED with the same input and return immediately;
# the detached copy (--detached) finishes the work independently.
if [ "${1:-}" != "--detached" ]; then
  self0="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if command -v setsid >/dev/null 2>&1; then
    printf '%s' "$input" | setsid "$self0" --detached >/dev/null 2>&1 &
  else
    printf '%s' "$input" | nohup "$self0" --detached >/dev/null 2>&1 &
  fi
  exit 0
fi

# App root: this script is symlinked into ~/.claude/hooks/ but its real path is in the app repo.
# `cd -P` resolves that symlink physically — see the note in hooks/sync-session.sh.
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
. "$APP/bin/lib.sh"

# Which coding harness ended a session. Claude Code and Codex both hand a hook this same payload
# (session_id / transcript_path / cwd); a harness that doesn't (opencode) sets SCRUBJAY_HARNESS and
# synthesizes one. Everything harness-shaped below — the topic, the slug — comes from the adapter.
harness="$(sj_harness)"
sj_load_adapter "$harness" || exit 0

sid="$(printf '%s' "$input"  | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$input"  | jq -r '.cwd // empty')"
tpath="$(printf '%s' "$input"| jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0

# Codex declares transcript_path NULLABLE, and a harness may not keep a transcript file at all
# (opencode). When the payload doesn't name one, ask the adapter to find (or produce) it.
[ -n "$tpath" ] || tpath="$(sjh_find_live_transcript "$cwd" "$sid" 2>/dev/null)"
host="$(sj_host)"
DATA="$(sj_data 2>/dev/null || true)"

# ---- 1) session line + chat index + auto-sync the whole data repo ----
if [ -n "$DATA" ] && [ -d "$DATA" ]; then
  LOG="$DATA/logs/$host.log"; mkdir -p "$DATA/logs"; touch "$LOG"
  ts="$(date '+%Y-%m-%d %H:%M')"

  # 1a) append the session's catalogue row (write-once; sj_log_row in bin/lib.sh is the single
  #     writer of that format — bin/sj-reconcile.sh writes the same row for a session that ended
  #     without ever reaching this hook). SCRUBJAY_TOPIC is the model-authored essence /sjlog
  #     passes in; empty on the automatic path, where the row falls back to the first user prompt.
  sj_log_row "$LOG" "$sid" "$cwd" "$tpath" "$harness" "$host" "$ts" "${SCRUBJAY_TOPIC:-}"

  # 1b) refresh this host's chats index (cheap, idempotent — a chat just ended). It indexes
  #     ~/.claude/projects/, so it only means anything for the claude harness.
  [ "$harness" = claude ] && "$APP/bin/claude-index-chats.sh" >/dev/null 2>&1 || true

  # 1c) commit + push EVERYTHING in the data repo so nothing needs a manual sync: the row, the
  #     chat index, plus any memory/ templates/ hosts/ settings/ edits.
  sj_data_push "auto-sync (session end): $host $ts"

  # 1c-2) re-render the human-browsable chat table. AFTER the git block, not before: the push
  #       fallback above rebases onto origin, which is what brings OTHER hosts' log lines into
  #       this machine — rendering first would reliably miss the newest ones. --no-pull because
  #       that push/fetch just did it. Derived + .gitignore'd, so `git add -A` never stages it.
  #       See bin/sj-catalogue.sh.
  "$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1 || true
fi

# ---- 1d) publish cross-machine memory to its own NAS-hosted git repo (not GitHub) ----
# Memory holds sensitive paths, so it rides its own self-hosted repo over WireGuard, separate
# from the data repo above. No-op if memory sync isn't configured on this machine.
"$APP/bin/memory-sync.sh" push >/dev/null 2>&1 || true

# ---- 2) relay the full transcript + the session's other records (pluggable backend) ----
if [ "${SCRUBJAY_NOSHIP:-0}" != "1" ] && [ -s "${tpath:-}" ]; then
  slug="$(sjh_session_slug "$tpath" "$cwd")"
  SCRUBJAY_HARNESS="$harness" \
    "$APP/bin/ship-transcript.sh" "$tpath" "$slug" "$sid" "$host" "$cwd" >/dev/null 2>&1 || true
fi

exit 0
