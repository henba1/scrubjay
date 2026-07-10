#!/usr/bin/env bash
# SessionEnd hook — fires once when a Claude Code session ends.
#   1) append one human-readable line to <data>/logs/<host>.log  (commit + push)
#   2) relay the full transcript via ship-transcript.sh (pluggable backend)
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
  self0="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  if command -v setsid >/dev/null 2>&1; then
    printf '%s' "$input" | setsid "$self0" --detached >/dev/null 2>&1 &
  else
    printf '%s' "$input" | nohup "$self0" --detached >/dev/null 2>&1 &
  fi
  exit 0
fi

# App root: this script is symlinked into ~/.claude/hooks/ but its real path is in the app repo.
self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
APP="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)" || exit 0
. "$APP/bin/lib.sh"

sid="$(printf '%s' "$input"  | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$input"  | jq -r '.cwd // empty')"
tpath="$(printf '%s' "$input"| jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0
host="$(sj_host)"
DATA="$(sj_data 2>/dev/null || true)"

# ---- 1) session line + chat index + auto-sync the whole data repo ----
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

  # 1c) commit + push EVERYTHING in the data repo so nothing needs a manual sync:
  #     log line, chat index, plus any memory/ templates/ hosts/ settings/ edits.
  #     .gitignore blocks secrets/transcripts (*.credentials*, *.jsonl, .claude.json),
  #     so `git add -A` can never stage those.
  if [ "${SCRUBJAY_LOG_NOGIT:-0}" != "1" ]; then
    (
      cd "$DATA" || exit 0

      # Self-heal before touching anything. A previous session's push fallback may have
      # left an interrupted rebase/merge (a conflict, or — more insidiously — a commit
      # that went empty and made rebase pause). If we don't clear it, `git add -A` below
      # commits onto the DETACHED rebase HEAD (even baking conflict markers into files),
      # every push silently no-ops, and the wedge compounds one commit per session. This
      # is exactly the July-2026 henpi failure. Aborting is safe: it just drops the
      # partial replay; our content lives in the working tree and re-commits cleanly.
      if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        git rebase --abort 2>/dev/null || true
      elif [ -f .git/MERGE_HEAD ]; then
        git merge --abort 2>/dev/null || true
      fi
      # Commits on a detached HEAD can never push — bail rather than orphan work.
      git symbolic-ref -q HEAD >/dev/null 2>&1 || exit 0

      git add -A 2>/dev/null
      git diff --cached --quiet 2>/dev/null && exit 0   # nothing to commit
      # Never commit a tree carrying conflict markers (unambiguous start/end lines).
      git diff --cached | grep -qE '^\+(<{7} |>{7} )' && exit 0
      git commit -q -m "auto-sync (session end): $host $ts" 2>/dev/null || exit 0
      if ! timeout 20 git push -q 2>/dev/null; then
        # Remote moved on: rebase our commit onto it and retry. What makes this wedge-proof
        # where a bare `git pull --rebase` was not is that nothing here can stop on a conflict:
        #   * append-only logs union both sides (.gitattributes: logs/*.log merge=union);
        #   * for any *shared* file that genuinely diverged — e.g. plugins/known_marketplaces.json
        #     or settings — `-X ours` takes origin's copy (during a rebase "ours" is the upstream
        #     we replay onto) instead of pausing. A machine's auto-sync must never fork shared
        #     config; deliberate shared edits are made by hand, not by this fallback. A bare pull
        #     --rebase aborted on the first such conflict and left the machine's commits stacking
        #     locally forever — the July-2026 hensipi wedge.
        # Belt and suspenders: if anything still fails, abort so the next session starts clean.
        if timeout 20 git fetch -q origin 2>/dev/null \
           && timeout 30 git rebase -X ours -q origin/main 2>/dev/null; then
          timeout 20 git push -q 2>/dev/null || true
        else
          git rebase --abort 2>/dev/null || true
        fi
      fi
    ) >/dev/null 2>&1 || true
  fi
fi

# ---- 1d) publish cross-machine memory to its own NAS-hosted git repo (not GitHub) ----
# Memory holds sensitive paths, so it rides its own self-hosted repo over WireGuard, separate
# from the data repo above. No-op if memory sync isn't configured on this machine.
"$APP/bin/memory-sync.sh" push >/dev/null 2>&1 || true

# ---- 2) relay the full transcript (pluggable backend) ----
if [ "${SCRUBJAY_NOSHIP:-0}" != "1" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
  slug="$(basename "$(dirname "$tpath")")"
  "$APP/bin/ship-transcript.sh" "$tpath" "$slug" "$sid" "$host" "$cwd" >/dev/null 2>&1 || true
fi

exit 0
