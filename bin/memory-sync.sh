#!/usr/bin/env bash
# Sync the cross-machine memory repo (its own git repo — self-hosted on the NAS for local/rsync-wg,
# a private GitHub repo for the git backend; remote-agnostic, so it just clones/pulls/pushes).
# Claude's per-project memory dirs are symlinked into this clone by claude-sync.sh, so a
# pull brings other machines' memories in and a push publishes this machine's.
#   usage: memory-sync.sh [pull|push]   (default: pull)
# Best-effort: clones on first use, never blocks a session, always exits 0.
#
# Config (~/.config/dotclaude/config):
#   DOTCLAUDE_MEMORY         local clone (default ~/.dotclaude/claude-memory)
#   DOTCLAUDE_MEMORY_REMOTE  the memory repo — a local path on the NAS box, ssh://…over-WG on
#                            clients, or a git@github.com:…private repo (git backend).
#                            Unset -> sync is off (this script no-ops).
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; dc_load_config

warn() { printf '\033[1;33m!\033[0m memory-sync: %s\n' "$*" >&2; }   # loud, but never blocks (exit stays 0)

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

# Resolve the branch once. Pull/push use an EXPLICIT `origin $branch` refspec so they work even
# when tracking isn't set yet (a bare `git pull` would otherwise error "no tracking information"
# and the rebase-retry below would never run). track() (re)asserts upstream every run — that's
# what keeps `git status` showing ahead/behind so a future divergence is visible, not silent.
branch="$(git branch --show-current 2>/dev/null)"; branch="${branch:-main}"
track() { git branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || true; }

case "$mode" in
  pull)
    timeout 30 git pull --rebase --autostash -q origin "$branch" 2>/dev/null || true
    track
    ;;
  push)
    git add -A 2>/dev/null
    git diff --cached --quiet 2>/dev/null && { track; exit 0; }   # nothing new to publish
    git commit -q -m "memory sync: $(dc_host) $(date '+%F %H:%M')" 2>/dev/null || exit 0
    if ! timeout 30 git push -q origin "$branch" 2>/dev/null; then
      # remote moved on (another machine pushed): tree is clean after commit, so rebase onto it + retry.
      if timeout 30 git pull --rebase --autostash -q origin "$branch" 2>/dev/null \
         && timeout 30 git push -q origin "$branch" 2>/dev/null; then
        :
      else
        # Genuinely couldn't reconcile (conflict / remote unreachable): surface it instead of
        # swallowing — the commit is safe locally but UNPUBLISHED until resolved by hand.
        warn "push to '$remote' failed and auto-reconcile didn't complete — local memory committed but NOT on the NAS."
        warn "resolve with:  git -C '$mem' pull --rebase && git -C '$mem' push"
      fi
    fi
    track
    ;;
  *) echo "memory-sync.sh: unknown mode '$mode' (use pull|push)" >&2; exit 0 ;;
esac

exit 0
