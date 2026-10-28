#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# SessionEnd hook — fires once when a coding session ends (any harness; see bin/adapters/) — and
# the Stop hook, which fires at the end of every TURN.
#   1) append one human-readable line to <data>/logs/<host>.log  (commit + push)
#   2) relay the session's records via ship-transcript.sh (pluggable backend)
# Never blocks the session: always exits 0.
#
# Per turn (`hook_event_name` = Stop) is what makes a session safe the moment a turn completes,
# rather than only once it ends cleanly: the relay and the memory push run every turn, the row is
# written on the first one. The data-repo push runs only when that row is new — a turn adds no
# commit to a repo every machine pulls — and the session end then refreshes the row (turns, size).
# Codex has only Stop, opencode publishes per idle; both land here the same way.
#
# Env knobs:  SCRUBJAY_LOG_NOGIT=1  (append log, skip its git)   CLAUDE_HOST=<name>
#             SCRUBJAY_NOSHIP=1     (skip transcript relay)
#             SCRUBJAY_TURN_SETTLE=<s> (per turn: wait for the transcript's last write; default 2)

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
event="$(printf '%s' "$input"| jq -r '.hook_event_name // empty')"
[ -n "$sid" ] || exit 0
turn=0; [ "$event" = Stop ] && turn=1

# ---- one publish per session at a time ----
# Turns end faster than a publish (a git push, a relay over WG), so runs for one session would
# overlap and race in the same repos. A turn that finds the session busy leaves a mark and goes:
# the run holding it publishes once more when it is done, and that later copy covers this turn.
# The session end instead waits its turn — it is the run that must not be skipped.
# mkdir is the lock because it is atomic everywhere; flock is not on macOS.
LOCK="${TMPDIR:-/tmp}/scrubjay-publish-${sid//[^A-Za-z0-9-]/}"
lock_take() {
  mkdir "$LOCK" 2>/dev/null && { echo $$ > "$LOCK/pid"; return 0; }
  # A holder that died (killed, machine slept through a reboot) must not block the session for good.
  local pid; pid="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null && { echo $$ > "$LOCK/pid"; return 0; }
  fi
  return 1
}
if [ "$turn" = 1 ]; then
  if ! lock_take; then
    : > "$LOCK.pending"
    # The holder may have finished between the two: then nobody would see the mark. Try once more.
    lock_take || exit 0
  fi
else
  for _ in $(seq 1 300); do lock_take && break; sleep 1; done   # at most 5 min, then go anyway
fi
lock_drop() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = $$ ] && rm -rf "$LOCK"; return 0; }
trap lock_drop EXIT

# Codex declares transcript_path NULLABLE, and a harness may not keep a transcript file at all
# (opencode). When the payload doesn't name one, ask the adapter to find (or produce) it.
[ -n "$tpath" ] || tpath="$(sjh_find_live_transcript "$cwd" "$sid" 2>/dev/null)"
host="$(sj_host)"
DATA="$(sj_data 2>/dev/null || true)"

# Steps 1d (memory push) and 2 (relay) touch neither the data repo nor each other, and each is a
# network round trip on a client (ssh over WG), as is the data-repo push to GitHub in step 1. So they
# run in the background alongside step 1, and the `wait` at the end joins them: /sjlog runs this
# synchronously, and its wall time becomes the slowest of the three rather than their sum.

publish() {
  rm -f "$LOCK.pending"
  # The harness may still be writing the turn's last record when Stop fires.
  [ "$turn" = 1 ] && sleep "${SCRUBJAY_TURN_SETTLE:-2}"

  # ---- 1d) publish cross-machine memory to its own NAS-hosted git repo (not GitHub) ----
  # Memory holds sensitive paths, so it rides its own self-hosted repo over WireGuard, separate
  # from the data repo below. No-op if memory sync isn't configured on this machine.
  sj_step memory run
  "$APP/bin/memory-sync.sh" push >/dev/null 2>&1 &

  # ---- 2) relay the full transcript + the session's other records (pluggable backend) ----
  if [ "${SCRUBJAY_NOSHIP:-0}" = "1" ]; then
    sj_step relay skip "disabled (SCRUBJAY_NOSHIP)"
  elif [ ! -s "${tpath:-}" ]; then
    sj_step relay skip "no transcript"
  else
    sj_step relay run
    slug="$(sjh_session_slug "$tpath" "$cwd")"
    SCRUBJAY_HARNESS="$harness" \
      "$APP/bin/ship-transcript.sh" "$tpath" "$slug" "$sid" "$host" "$cwd" >/dev/null 2>&1 &
  fi

  # ---- 1) session line + chat index + auto-sync the whole data repo ----
  if [ -n "$DATA" ] && [ -d "$DATA" ]; then
    LOG="$DATA/logs/$host.log"; mkdir -p "$DATA/logs"; touch "$LOG"
    ts="$(date '+%Y-%m-%d %H:%M')"

    # 1a) append the session's catalogue row (sj_log_row in bin/lib.sh is the single
    #     writer of that format — bin/sj-reconcile.sh writes the same row for a session that ended
    #     without ever reaching this hook). SCRUBJAY_TOPIC is the model-authored essence /sjlog
    #     passes in; empty on the automatic path, where the row falls back to the session's first
    #     real user prompt — or, when it typed none, to the slash command it ran.
    #     A turn writes the row only if there is none; the end (and /sjlog) refreshes it.
    if [ "$turn" = 1 ]; then
      sj_log_row "$LOG" "$sid" "$cwd" "$tpath" "$harness" "$host" "$ts" "${SCRUBJAY_TOPIC:-}"
    else
      sj_log_row "$LOG" "$sid" "$cwd" "$tpath" "$harness" "$host" "$ts" "${SCRUBJAY_TOPIC:-}" refresh
    fi
    wrote=$?
    if [ "$wrote" = 0 ]; then sj_step catalogue ok "row for ${sid:0:8}"
    else sj_step catalogue skip "row for ${sid:0:8} up to date"; fi
    # A later turn has nothing for the data repo: the row is there, and an index refresh and a push
    # to GitHub every turn would be the cost of this hook, not of the session.
    if [ "$turn" = 1 ] && [ "$wrote" != 0 ]; then wait; return 0; fi

    # 1b) refresh this host's chats index (cheap, idempotent — a chat just ended). It indexes
    #     ~/.claude/projects/, so it only means anything for the claude harness.
    [ "$harness" = claude ] && "$APP/bin/claude-index-chats.sh" >/dev/null 2>&1 || true

    # 1c) commit + push EVERYTHING in the data repo so nothing needs a manual sync: the row, the
    #     chat index, plus any memory/ templates/ hosts/ settings/ edits.
    sj_step data run
    if [ "$turn" = 1 ]; then sj_data_push "auto-sync (first turn): $host $ts"
    else sj_data_push "auto-sync (session end): $host $ts"; fi
    # sj_data_push is silent by contract; whether it landed is whether anything is left unpushed.
    if [ "${SCRUBJAY_LOG_NOGIT:-0}" = "1" ]; then sj_step data skip "git disabled"
    else
      ahead="$(git -C "$DATA" rev-list --count '@{u}..HEAD' 2>/dev/null)"
      case "$ahead" in
        0)  sj_step data ok "in sync with origin" ;;
        '') sj_step data skip "no upstream" ;;
        *)  sj_step data fail "$ahead commit(s) not pushed" ;;
      esac
    fi

    # 1c-2) re-render the human-browsable chat table. AFTER the git block, not before: the push
    #       fallback above rebases onto origin, which is what brings OTHER hosts' log lines into
    #       this machine — rendering first would reliably miss the newest ones. --no-pull because
    #       that push/fetch just did it. Derived + .gitignore'd, so `git add -A` never stages it.
    #       See bin/sj-catalogue.sh.
    "$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1 || true
  else
    sj_step data skip "no data repo"
  fi

  wait   # join 1d + 2: the detached copy must not exit before they finish either
}

# Turns that ended while this ran left a mark: publish once more, for all of them. Look again after
# letting go — a turn may have marked just before — and go on only if the lock is still free.
while :; do
  publish
  while [ -e "$LOCK.pending" ]; do publish; done
  lock_drop
  if [ -e "$LOCK.pending" ] && lock_take; then continue; fi
  break
done
exit 0
