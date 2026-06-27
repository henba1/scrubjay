#!/usr/bin/env bash
# Sync the cross-machine memory repo (self-hosted on the NAS over WireGuard — never GitHub).
# Claude's per-project memory dirs are symlinked into this clone by claude-sync.sh, so a
# pull brings other machines' memories in and a push publishes this machine's.
#   usage: memory-sync.sh [pull|push]   (default: pull)
# Best-effort: clones on first use, never blocks a session, always exits 0.
#
# Config (~/.config/dotclaude/config):
#   DOTCLAUDE_MEMORY         local clone (default ~/.dotclaude/claude-memory)
#   DOTCLAUDE_MEMORY_REMOTE  bare repo — local path on the NAS box, ssh://…over-WG on clients.
#                            Unset -> sync is off (this script no-ops).
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; dc_load_config

mode="${1:-pull}"
mem="$(dc_memory)"
remote="$(dc_memory_remote)"
[ -n "$remote" ] || exit 0                      # memory git sync not configured on this machine

# First use: clone the bare repo (creating an empty working tree if the repo has no commits yet).
if [ ! -d "$mem/.git" ]; then
  mkdir -p "$(dirname "$mem")" 2>/dev/null || exit 0
  timeout 30 git clone -q "$remote" "$mem" 2>/dev/null || {
    # remote unreachable, or empty/non-existent: start a local repo pointed at it so a later
    # push can populate the bare repo. (An empty `git clone` of a freshly-init'd bare repo
    # already succeeds, so this mainly covers the unreachable case.)
    git init -q "$mem" 2>/dev/null || exit 0
    git -C "$mem" remote add origin "$remote" 2>/dev/null || true
  }
fi
[ -d "$mem/.git" ] || exit 0

cd "$mem" || exit 0
git config pull.rebase true 2>/dev/null || true

case "$mode" in
  pull)
    timeout 30 git pull --rebase --autostash -q 2>/dev/null || true
    ;;
  push)
    git add -A 2>/dev/null
    git diff --cached --quiet 2>/dev/null && exit 0   # nothing new to publish
    git commit -q -m "memory sync: $(dc_host) $(date '+%F %H:%M')" 2>/dev/null || exit 0
    # -u: set upstream on first push so later `pull --rebase` has tracking info.
    if ! timeout 30 git push -qu origin HEAD 2>/dev/null; then
      # remote moved on (another machine pushed): the tree is clean after commit, so rebase+retry
      timeout 30 git pull --rebase --autostash -q 2>/dev/null && timeout 30 git push -qu origin HEAD 2>/dev/null
    fi
    ;;
  *) echo "memory-sync.sh: unknown mode '$mode' (use pull|push)" >&2; exit 0 ;;
esac

exit 0
