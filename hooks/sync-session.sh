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
[ "${SCRUBJAY_NOSYNC:-0}" = "1" ] && exit 0
cat >/dev/null 2>&1 || true   # drain hook stdin, ignore

# App root. `cd -P` resolves symlinked path components physically, which is the whole game here:
# we are invoked as ~/.claude/hooks/<this>, and ~/.claude/hooks is a symlink to <app>/hooks
# (bin/claude-sync.sh). A logical `cd` would apply ".." to the *link* path and land in ~/.claude,
# where bin/lib.sh does not exist — every hook would then exit 0 in silence. This used to lean on
# `readlink -f`, which older macOS/BSD lacks, and whose fallback did exactly that. -P is POSIX.
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
. "$APP/bin/lib.sh"
DATA="$(sj_data 2>/dev/null || true)"

# 1) pull latest from other machines (best-effort, fast). DATA = your config/content;
#    APP = the scripts & hooks themselves, so hook/script fixes also propagate on their
#    own. --ff-only never clobbers local edits (it just no-ops on a dirty/diverged tree).
if [ "${SCRUBJAY_SYNC_NOPULL:-0}" != "1" ]; then
  # The APP pull below is scrubjay's ONLY self-update path, and it's guarded on .git — so an
  # install from a source tarball/zip would skip it forever, silently, and rot. Say it out loud
  # (stdout lands in the session's context, so the assistant surfaces it).
  sj_is_clone || printf 'scrubjay: the app at %s is not a git clone, so it can never self-update. Source tarballs are not a supported install — reinstall with `git clone`.\n' "$APP"
  for repo in "$DATA" "$APP"; do
    [ -n "$repo" ] && [ -d "$repo/.git" ] && \
      ( cd "$repo" && sj_timeout 15 git pull --ff-only -q 2>/dev/null ) || true
  done
  # git backend only: refresh the scrubjay-chats clone so the local sjmcp archive spans every
  # machine's sessions (not just this one's) before claude-sync registers/serves it. Best-effort;
  # --ff-only just no-ops on a diverged tree (e.g. local ships that haven't pushed yet) — but
  # unlike the DATA repo (which gets a visible warning from sj-catalogue.sh below), a diverged
  # chats clone used to fail silently: sj_recall/sj_get read this clone directly with no pull and
  # no staleness check, so sessions that exist on origin (relayed by another machine) would
  # silently vanish from search here. Surface it the same way the relay-failure breadcrumb does.
  if [ "${SCRUBJAY_TRANSCRIPT_BACKEND:-git}" = "git" ]; then
    chats="$(sj_chats 2>/dev/null || true)"
    if [ -n "$chats" ] && [ -d "$chats/.git" ]; then
      if ! ( cd "$chats" && sj_timeout 20 git pull --ff-only -q 2>/dev/null ); then
        behind="$( cd "$chats" && git rev-list --count HEAD..@'{u}' 2>/dev/null )"
        if [ -n "${behind:-}" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
          printf 'scrubjay: the local chats archive is %s commit(s) behind origin and could not fast-forward — it has diverged, likely from local ships that failed to push. /sjrecall and sj_get may silently miss sessions from other machines until this is resolved (cd %s && git pull --rebase), or fix the relay push if it keeps recurring.\n' "$behind" "$chats"
        fi
      fi
    fi
  fi
fi

# 1b) pull cross-machine memory from its own NAS-hosted git repo (no-op if not configured),
#     BEFORE claude-sync links the per-project memory dirs at it, so others' memory is present.
"$APP/bin/memory-sync.sh" pull >/dev/null 2>&1 || true

# 2) apply into each harness's config root (idempotent; mostly a no-op thanks to symlinks)
"$APP/bin/sync-config.sh" >/dev/null 2>&1 || true

# 2b) re-render logs/CATALOGUE.md — the human-browsable chat table — now that the pull in (1)
#     has brought in other machines' log lines. --no-pull: (1) already did it, and honors
#     SCRUBJAY_SYNC_NOPULL, which a second pull here would quietly override.
#     Derived + .gitignore'd; see bin/sj-catalogue.sh.
"$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1 || true

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

exit 0
