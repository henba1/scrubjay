#!/usr/bin/env bash
# SessionStart hook — fires once when a Claude Code session begins.
# Keeps this machine's config fresh with zero manual steps:
#   1) git pull --ff-only the data repo (so config edited on another machine arrives)
#   2) claude-sync.sh  -> re-materialize ~/.claude/settings.json + fix any missing symlinks
# Symlinked scopes (CLAUDE.md, commands, agents, hooks) go live on pull alone; sync only
# has real work when settings.base.json / the host overlay changed.
# Never blocks the session: always exits 0.
#
# Env knobs:  DOTCLAUDE_NOSYNC=1  (skip entirely)   DOTCLAUDE_SYNC_NOPULL=1  (sync without pull)
#             CLAUDE_HOST=<name>
[ "${DOTCLAUDE_NOSYNC:-0}" = "1" ] && exit 0
cat >/dev/null 2>&1 || true   # drain hook stdin, ignore

self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
APP="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)" || exit 0
. "$APP/bin/lib.sh"
DATA="$(dc_data 2>/dev/null || true)"

# 1) pull latest from other machines (best-effort, fast). DATA = your config/content;
#    APP = the scripts & hooks themselves, so hook/script fixes also propagate on their
#    own. --ff-only never clobbers local edits (it just no-ops on a dirty/diverged tree).
if [ "${DOTCLAUDE_SYNC_NOPULL:-0}" != "1" ]; then
  for repo in "$DATA" "$APP"; do
    [ -n "$repo" ] && [ -d "$repo/.git" ] && \
      ( cd "$repo" && timeout 15 git pull --ff-only -q 2>/dev/null ) || true
  done
fi

# 2) apply into ~/.claude (idempotent; mostly a no-op thanks to symlinks)
"$APP/bin/claude-sync.sh" >/dev/null 2>&1 || true

exit 0
