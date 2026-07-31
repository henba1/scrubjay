#!/usr/bin/env bash
# Sync the cross-machine memory repo (its own git repo — self-hosted on the NAS for local/rsync-wg,
# a private GitHub repo for the git backend; remote-agnostic, so it just clones/pulls/pushes).
# Claude's per-project memory dirs are symlinked into this clone by claude-sync.sh, so a
# pull brings other machines' memories in and a push publishes this machine's.
#   usage: memory-sync.sh [pull|push]   (default: pull)
# Best-effort: clones on first use, never blocks a session, always exits 0.
#
# Config (~/.config/scrubjay/config):
#   SCRUBJAY_MEMORY         local clone (default ~/.scrubjay/scrubjay-memory)
#   SCRUBJAY_MEMORY_REMOTE  the memory repo — a local path on the NAS box, ssh://…over-WG on
#                            clients, or a git@github.com:…private repo (git backend).
#                            Unset -> sync is off (this script no-ops).
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

warn() { printf '\033[1;33m!\033[0m memory-sync: %s\n' "$*" >&2; }   # loud, but never blocks (exit stays 0)

mode="${1:-pull}"
mem="$(sj_memory)"
remote="$(sj_memory_remote)"
[ -n "$remote" ] || exit 0                      # memory git sync not configured on this machine

# First use: clone the bare repo (creating an empty working tree if the repo has no commits yet).
if [ ! -d "$mem/.git" ]; then
  mkdir -p "$(dirname "$mem")" 2>/dev/null || exit 0
  sj_timeout 30 git clone -q "$remote" "$mem" 2>/dev/null || {
    # remote unreachable, or empty/non-existent: start a local repo pointed at it so a later
    # push can populate the bare repo. (An empty `git clone` of a freshly-init'd bare repo
    # already succeeds, so this mainly covers the unreachable case.)
    git init -q "$mem" 2>/dev/null || exit 0
    # Pin the unborn branch to main. `git init` names it after init.defaultBranch, which is still
    # `master` on plenty of installs — and the resulting repo then pulls/pushes `origin master`
    # against a bare repo whose only branch is `main`, so it can NEVER reconcile. Silent, permanent
    # island; observed on a real host. (symbolic-ref, not `init -b`: works on git < 2.28 too.)
    git -C "$mem" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git -C "$mem" remote add origin "$remote" 2>/dev/null || true
  }
fi
[ -d "$mem/.git" ] || exit 0

cd "$mem" || exit 0
git config pull.rebase true 2>/dev/null || true

# Keep origin honest. Everything below talks to `origin`, but origin's URL was frozen at clone
# time — so editing SCRUBJAY_MEMORY_REMOTE in the config appeared to work and changed nothing,
# and a renamed/moved bare repo stranded every push behind a dead path while sync reported
# success. The config is the source of truth; reassert it on every run.
cur="$(git remote get-url origin 2>/dev/null)" || cur=""
if [ "$cur" != "$remote" ]; then
  if [ -z "$cur" ]; then git remote add origin "$remote" 2>/dev/null || true
  else
    git remote set-url origin "$remote" 2>/dev/null || true
    warn "memory remote moved: '$cur' -> '$remote' (origin re-pointed from the config)"
  fi
fi

# Resolve the branch once. Pull/push use an EXPLICIT `origin $branch` refspec so they work even
# when tracking isn't set yet (a bare `git pull` would otherwise error "no tracking information"
# and the rebase-retry below would never run). track() (re)asserts upstream every run — that's
# what keeps `git status` showing ahead/behind so a future divergence is visible, not silent.
branch="$(git branch --show-current 2>/dev/null)"; branch="${branch:-main}"
track() { git branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || true; }

case "$mode" in
  pull)
    if sj_timeout 30 git pull --rebase --autostash -q origin "$branch" 2>/dev/null; then
      sj_record_memory_sync ok pull "$remote"
    else
      # A failed pull is not fatal (the local memory is still readable), but it does mean this
      # machine is running on a stale view of everyone else's — worth surfacing, not swallowing.
      sj_record_memory_sync fail pull "$remote" "branch=$branch"
    fi
    track
    ;;
  push)
    git add -A 2>/dev/null
    if git diff --cached --quiet 2>/dev/null; then
      # Nothing new to stage — which is NOT the same as nothing to publish. An earlier run may
      # have committed while the remote was unreachable (the normal first-run state on a WG client
      # whose key isn't authorized yet), leaving commits stranded locally. Exiting "ok" here
      # asserted success for a repo that had never pushed anything. Only claim success once the
      # branch is provably not ahead; otherwise fall through and push what's already committed.
      # An unknown count (no remote-tracking ref yet) counts as ahead — try, don't assume.
      ahead="$(git rev-list --count "origin/$branch..$branch" 2>/dev/null)" || ahead=""
      # `skip`, not `ok`: nothing was published, so the remote was never contacted and this run
      # proves nothing about reachability. Claiming success here is what let a cut-off machine
      # report green every session while its pull had been failing for weeks.
      if [ "$ahead" = 0 ]; then track; sj_record_memory_sync skip push "$remote" "nothing-to-publish"; exit 0; fi
    else
      git commit -q -m "memory sync: $(sj_host) $(date '+%F %H:%M')" 2>/dev/null || exit 0
    fi
    if ! sj_timeout 30 git push -q origin "$branch" 2>/dev/null; then
      # remote moved on (another machine pushed): tree is clean after commit, so rebase onto it + retry.
      if sj_timeout 30 git pull --rebase --autostash -q origin "$branch" 2>/dev/null \
         && sj_timeout 30 git push -q origin "$branch" 2>/dev/null; then
        sj_record_memory_sync ok push "$remote"
      else
        # Genuinely couldn't reconcile (conflict / remote unreachable): surface it instead of
        # swallowing — the commit is safe locally but UNPUBLISHED until resolved by hand. The
        # breadcrumb is what actually reaches you: both callers are hooks that discard stderr.
        warn "push to '$remote' failed and auto-reconcile didn't complete — local memory committed but NOT on the NAS."
        warn "resolve with:  git -C '$mem' pull --rebase && git -C '$mem' push"
        sj_record_memory_sync fail push "$remote" "ahead=$(git rev-list --count origin/$branch..$branch 2>/dev/null || echo '?')"
      fi
    else
      sj_record_memory_sync ok push "$remote"
    fi
    track
    ;;
  *) echo "memory-sync.sh: unknown mode '$mode' (use pull|push)" >&2; exit 0 ;;
esac

exit 0
