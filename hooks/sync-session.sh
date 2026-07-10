#!/usr/bin/env bash
# SessionStart hook — fires once when a Claude Code session begins.
# Keeps this machine's config fresh with zero manual steps:
#   1) git pull --ff-only the data repo (so config edited on another machine arrives)
#   2) claude-sync.sh  -> re-materialize ~/.claude/settings.json + fix any missing symlinks
# Symlinked scopes (CLAUDE.md, commands, agents, hooks) go live on pull alone; sync only
# has real work when settings.base.json / the host overlay changed.
# Never blocks the session: always exits 0.
#
# Env knobs:  SCRUBJAY_NOSYNC=1  (skip entirely)   SCRUBJAY_SYNC_NOPULL=1  (sync without pull)
#             CLAUDE_HOST=<name>
[ "${SCRUBJAY_NOSYNC:-0}" = "1" ] && exit 0
cat >/dev/null 2>&1 || true   # drain hook stdin, ignore

self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
APP="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)" || exit 0
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
      ( cd "$repo" && timeout 15 git pull --ff-only -q 2>/dev/null ) || true
  done
  # git backend only: refresh the scrubjay-chats clone so the local sjmcp archive spans every
  # machine's sessions (not just this one's) before claude-sync registers/serves it. Best-effort;
  # --ff-only just no-ops on a diverged tree (e.g. local ships that haven't pushed yet).
  if [ "${SCRUBJAY_TRANSCRIPT_BACKEND:-git}" = "git" ]; then
    chats="$(sj_chats 2>/dev/null || true)"
    [ -n "$chats" ] && [ -d "$chats/.git" ] && \
      ( cd "$chats" && timeout 20 git pull --ff-only -q 2>/dev/null ) || true
  fi
fi

# 1b) pull cross-machine memory from its own NAS-hosted git repo (no-op if not configured),
#     BEFORE claude-sync links the per-project memory dirs at it, so others' memory is present.
"$APP/bin/memory-sync.sh" pull >/dev/null 2>&1 || true

# 2) apply into ~/.claude (idempotent; mostly a no-op thanks to symlinks)
"$APP/bin/claude-sync.sh" >/dev/null 2>&1 || true

# 3) surface a prior transcript-relay failure. ship-transcript.sh drops a breadcrumb when the
#    primary push fails; the relay swallows its own errors (best-effort, must never block a
#    session), so without this a dead/unauthorized relay key eats transcripts unnoticed. Printing
#    to stdout adds it to the session's context, so the assistant flags it. Clears itself once a
#    later ship succeeds (the breadcrumb is rewritten to result=ok).
sfile="$(sj_ship_status_file 2>/dev/null || echo "$HOME/.config/scrubjay/last-ship")"
if [ -s "$sfile" ] && grep -q '^result=fail' "$sfile" 2>/dev/null; then
  printf 'scrubjay: the last transcript relay from this machine FAILED — recent sessions may not have reached the archive. Check the relay SSH key / authorized_keys on the receiver, then re-ship. Breadcrumb: %s\n' "$(cat "$sfile")"
fi

exit 0
