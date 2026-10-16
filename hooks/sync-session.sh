#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# SessionStart hook — fires once when a coding session begins (any harness: Claude Code fires it
# from settings.json; another harness's adapter is responsible for calling it — see bin/adapters/).
# Keeps this machine's config fresh with zero manual steps:
#   1) git pull --ff-only the data repo (so config edited on another machine arrives)
#   2) sync-config.sh  -> re-materialize settings + fix any missing symlinks, per harness
# Symlinked scopes (CLAUDE.md, commands, agents, hooks) go live on pull alone; sync only
# has real work when settings.base.json / the host overlay changed.
# Never blocks the session: always exits 0.
#
# Env knobs:  SCRUBJAY_NOSYNC=1  (skip entirely)   SCRUBJAY_SYNC_NOPULL=1  (sync without pull)
#             CLAUDE_HOST=<name>
# --report (the /sjsync command): print the step report at the end. Never on the hook path —
# stdout there is the session's context, and a clean sync has nothing to tell it.
[ "${SCRUBJAY_NOSYNC:-0}" = "1" ] && exit 0
report=0; [ "${1:-}" = "--report" ] && report=1
# Read the payload rather than discarding it: step 2c needs this session's own id, so that the
# reconcile pass cannot mistake the session it is running inside for one that died. Everything
# else here ignores it. `|| true` — a harness that sends nothing must not wedge the hook.
input="$(cat 2>/dev/null)" || input=""

# App root. `cd -P` resolves symlinked path components physically, which is the whole game here:
# we are invoked as ~/.claude/hooks/<this>, and ~/.claude/hooks is a symlink to <app>/hooks
# (bin/claude-sync.sh). A logical `cd` would apply ".." to the *link* path and land in ~/.claude,
# where bin/lib.sh does not exist — every hook would then exit 0 in silence. This used to lean on
# `readlink -f`, which older macOS/BSD lacks, and whose fallback did exactly that. -P is POSIX.
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
. "$APP/bin/lib.sh"
DATA="$(sj_data 2>/dev/null || true)"
sj_load_config   # in THIS shell: sj_data loads it only in its own subshell, so the backend check below saw the default
sj_progress_begin sync

# One repo's fast-forward pull, reported as a step (run in the background by the loop below).
pull_step() {  # pull_step <step> <repo> <timeout-secs>
  local before after
  before="$(git -C "$2" rev-parse HEAD 2>/dev/null)"
  if ( cd "$2" && sj_timeout "$3" git pull --ff-only -q 2>/dev/null ); then
    after="$(git -C "$2" rev-parse HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then sj_step "$1" ok "up to date"; else sj_step "$1" ok "updated"; fi
  else
    sj_step "$1" fail "pull failed (diverged, dirty or unreachable)"
  fi
}

# 1) pull latest from other machines (best-effort, fast). DATA = your config/content;
#    APP = the scripts & hooks themselves, so hook/script fixes also propagate on their
#    own. --ff-only never clobbers local edits (it just no-ops on a dirty/diverged tree).
if [ "${SCRUBJAY_SYNC_NOPULL:-0}" != "1" ]; then
  # The APP pull below is scrubjay's ONLY self-update path, and it's guarded on .git — so an
  # install from a source tarball/zip would skip it forever, silently, and rot. Say it out loud
  # (stdout lands in the session's context, so the assistant surfaces it).
  sj_is_clone || printf 'scrubjay: the app at %s is not a git clone, so it can never self-update. Source tarballs are not a supported install — reinstall with `git clone`.\n' "$APP"
  # Independent repos, each a network round-trip — pull them concurrently (chats below too).
  for pair in "data:$DATA" "app:$APP"; do
    step="${pair%%:*}"; repo="${pair#*:}"
    [ -n "$repo" ] && [ -d "$repo/.git" ] && { sj_step "$step" run; pull_step "$step" "$repo" 15 & }
  done
  # git backend only: refresh the scrubjay-chats clone so the local sjmcp archive spans every
  # machine's sessions (not just this one's) before claude-sync registers/serves it. Best-effort;
  # --ff-only just no-ops on a diverged tree (e.g. local ships that haven't pushed yet).
  if [ "${SCRUBJAY_TRANSCRIPT_BACKEND:-git}" = "git" ]; then
    chats="$(sj_chats 2>/dev/null || true)"
    [ -n "$chats" ] && [ -d "$chats/.git" ] && { sj_step chats run; pull_step chats "$chats" 20 & }
  fi
fi

# 1b) pull cross-machine memory from its own NAS-hosted git repo (no-op if not configured),
#     BEFORE claude-sync links the per-project memory dirs at it, so others' memory is present.
#     Concurrent with the pulls above; `wait` joins them all before anything reads the results.
sj_step memory run
{ "$APP/bin/memory-sync.sh" pull >/dev/null 2>&1 || true; } &
wait


# 2) apply into each harness's config root (idempotent; mostly a no-op thanks to symlinks)
sj_step config run
if "$APP/bin/sync-config.sh" >/dev/null 2>&1; then sj_step config ok "applied"
else sj_step config fail "sync-config.sh failed"; fi

# 2b) re-render logs/CATALOGUE.md — the human-browsable chat table — now that the pull in (1)
#     has brought in other machines' log lines. --no-pull: (1) already did it, and honors
#     SCRUBJAY_SYNC_NOPULL, which a second pull here would quietly override.
#     Derived + .gitignore'd; see bin/sj-catalogue.sh.
"$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1 || true

# 2c) catalogue + archive any session that ended WITHOUT the session-end hook ever firing (kill -9,
#     closed terminal, dropped SSH, power cut). Nothing else can notice those: the relay breadcrumb
#     in (3) is written by a ship that never ran, so the absence is silent. This is the one place
#     that looks. Cheap when there is nothing to find — a find plus a stat per transcript, no
#     transcript read — and capped so a backlog cannot turn one session's startup into a bulk
#     upload. Its stdout is deliberately NOT swallowed: that is how the recovery gets reported.
#     SCRUBJAY_NORECONCILE=1 opts out. See bin/sj-reconcile.sh.
if [ "${SCRUBJAY_NORECONCILE:-0}" != "1" ]; then
  self_sid=""
  command -v jq >/dev/null 2>&1 && \
    self_sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  sj_step reconcile run
  "$APP/bin/sj-reconcile.sh" ${self_sid:+--exclude "$self_sid"} 2>/dev/null || true
  sj_step reconcile ok "orphaned sessions checked"
fi

# 3) surface a prior transcript-relay failure. ship-transcript.sh drops a breadcrumb when the
#    primary push fails; the relay swallows its own errors (best-effort, must never block a
#    session), so without this a dead/unauthorized relay key eats transcripts unnoticed. Printing
#    to stdout adds it to the session's context, so the assistant flags it. Clears itself once a
#    later ship succeeds (the breadcrumb is rewritten to result=ok).
sfile="$(sj_ship_status_file 2>/dev/null || echo "$HOME/.config/scrubjay/last-ship")"
if [ -s "$sfile" ] && grep -q '^result=fail' "$sfile" 2>/dev/null; then
  printf 'scrubjay: the last transcript relay from this machine FAILED — recent sessions may not have reached the archive. Check the relay SSH key / authorized_keys on the receiver, then re-ship. Breadcrumb: %s\n' "$(cat "$sfile")"
fi

# 3a) finish onboarding if the receiver has been authorized since last time. A p2p host cannot
#     authorize itself, so onboarding ends mid-way by design and the host syncs nothing until a
#     human pastes its key on the receiver. Rather than make the user remember to come back and
#     re-run the publish, probe here: the moment the key lands, catch up and clear the wait.
#     Costs one bounded probe per session, and ONLY while something is actually pending.
pfile="$(sj_pending_file 2>/dev/null || echo "$HOME/.config/scrubjay/pending-authorization")"
if [ -s "$pfile" ]; then
  while IFS="$(printf '\t')" read -r sub kind tgt; do
    [ -n "${sub:-}" ] || continue
    if sj_pending_authorized "$kind" "$tgt"; then
      case "$sub" in
        memory)
          # Publish whatever accumulated while the remote was refusing us.
          "$APP/bin/memory-sync.sh" pull >/dev/null 2>&1 || true
          "$APP/bin/memory-sync.sh" push >/dev/null 2>&1 || true
          printf 'scrubjay: this machine is now authorized for cross-machine memory — memory accumulated since onboarding has been published, and sync is live.\n' ;;
        relay)
          printf 'scrubjay: this machine is now authorized on the transcript receiver — session-end relay is live. Sessions recorded before now stayed local; re-ship them with bin/backfill-transcripts.sh if you want them archived.\n' ;;
        *) printf 'scrubjay: %s is now authorized on the receiver.\n' "$sub" ;;
      esac
      sj_clear_pending "$sub"
    else
      printf 'scrubjay: %s is NOT yet authorized on the receiver (%s), so it is syncing nothing. Add this host key to the receiver'"'"'s authorized_keys — the line was printed by onboarding, and a human with root on the receiver must paste it.\n' "$sub" "$tgt"
    fi
  done < "$pfile"
fi

# 3b) same for cross-machine memory. Its sync is best-effort and hook-invoked with stderr closed,
#     so a dead remote used to strand memory on one machine indefinitely while every session
#     reported success. Clears itself once a later pull/push succeeds.
#     The file carries one line per mode, so a failed pull stays visible even after a push that
#     had nothing to publish — hence no '^' anchor here.
mfile="$(sj_memory_status_file 2>/dev/null || echo "$HOME/.config/scrubjay/last-memory-sync")"
if [ -s "$mfile" ] && grep -q 'result=fail' "$mfile" 2>/dev/null; then
  printf 'scrubjay: cross-machine memory sync FAILED — this machine may be running on a stale view of memory, and anything it writes may not reach the others. Check SCRUBJAY_MEMORY_REMOTE and the memory-git SSH key. Breadcrumb: %s\n' "$(cat "$mfile")"
fi

sj_progress_end
[ "$report" = 1 ] && sj_progress_render
exit 0
