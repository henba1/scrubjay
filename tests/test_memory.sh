#!/usr/bin/env bash
# bin/memory-sync.sh — the cross-machine memory lifecycle.
#
# This file exists because memory sync used to be structurally untestable: tests/lib.sh pinned
# SCRUBJAY_MEMORY_REMOTE="" so no test would ever touch a real NAS, which also meant no test ever
# exercised the script at all. Four silent-failure bugs lived there as a result.
#
# The unlock is that memory is plain git: a bare repo *inside the sandbox* is a complete stand-in
# for the NAS, over file:// — hermetic, no network, no second machine. Every scenario below is a
# real failure that happened on a real host.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

# memory-sync commits, so the sandbox needs an identity (HOME is already redirected, so this
# writes to the sandbox's .gitconfig and cannot touch the developer's).
git config --global user.email "test@scrubjay.invalid"
git config --global user.name  "scrubjay tests"
# The bug-2 precondition: git's own default. Most machines have this unset, which means `master`.
git config --global init.defaultBranch master

MEM="$SANDBOX/memory"
sync() { SCRUBJAY_MEMORY="$MEM" SCRUBJAY_MEMORY_REMOTE="$1" bash "$APP/bin/memory-sync.sh" "$2"; }
seed_bare() {  # seed_bare <path> — a bare repo with one commit on main
  git init -q --bare -b main "$1"
  local w="$SANDBOX/seed.$$"; git init -q -b main "$w"
  echo seed > "$w/SEED.md"; git -C "$w" add -A; git -C "$w" commit -q -m seed
  git -C "$w" push -q "$1" main; rm -rf "$w"
}
crumb() { cat "$HOME/.config/scrubjay/last-memory-sync" 2>/dev/null; }

# ── the unreachable remote is the NORMAL first run ─────────────────────────────────────────────
# On the peer-to-peer backends a new machine cannot clone until a human authorizes its key on the
# receiver. So the clone-failure fallback is not an edge case — it is what every client does first.
section "first run against an unreachable remote falls back to a usable repo"
GONE="$SANDBOX/not-a-repo.git"
sync "$GONE" pull >/dev/null 2>&1
assert_file "a local repo was created anyway" "$MEM/.git/HEAD"
# BUG 2: `git init` takes the branch from init.defaultBranch. A `master` repo can never reconcile
# with a `main` bare repo — pull/push of `origin master` match nothing, permanently and silently.
assert_eq "the unborn branch is pinned to main, not init.defaultBranch" \
  "main" "$(git -C "$MEM" symbolic-ref --short HEAD 2>/dev/null)"
assert_eq "origin points at the configured remote" \
  "$GONE" "$(git -C "$MEM" remote get-url origin 2>/dev/null)"
# BUG 3: the failure has to leave a trace. Both callers are hooks that discard stderr, so the
# warning reached nobody and a dead remote went unnoticed for weeks.
assert_contains "a failure breadcrumb was recorded" "$(crumb)" "result=fail"

# ── commits made while the remote was down must still publish later ────────────────────────────
section "commits stranded by an unreachable remote publish once it appears"
mkdir -p "$MEM/-home-user-project"
echo "a memory written before the key was authorized" > "$MEM/-home-user-project/note.md"
sync "$GONE" push >/dev/null 2>&1
assert_contains "push failed while the remote was absent" "$(crumb)" "result=fail"
assert_eq "but the memory was committed locally" \
  "1" "$(git -C "$MEM" log --oneline -- -home-user-project 2>/dev/null | wc -l | tr -d ' ')"

# The human authorizes the key / the NAS comes back: same path, now a real repo.
git init -q --bare -b main "$GONE"
sync "$GONE" push >/dev/null 2>&1
# BUG 4: `git add -A` stages nothing on this run (it was committed above), and the old code read
# that as "nothing to publish", reported ok and exited — stranding the commit forever with no
# path out. Nothing-to-stage is not nothing-to-push.
assert_eq "the stranded commit reached the remote" \
  "1" "$(git --git-dir="$GONE" log --oneline main -- -home-user-project 2>/dev/null | wc -l | tr -d ' ')"
assert_contains "and the breadcrumb clears to ok" "$(crumb)" "result=ok"

# ── a genuinely clean run stays quiet ──────────────────────────────────────────────────────────
section "a no-op push is reported as success, not as work"
before="$(git --git-dir="$GONE" rev-parse main)"
sync "$GONE" push >/dev/null 2>&1
assert_eq "no empty commit was created" "$before" "$(git --git-dir="$GONE" rev-parse main)"
assert_contains "still reports ok" "$(crumb)" "result=ok"

# ── the config is the source of truth for where memory goes ────────────────────────────────────
# BUG 1: origin was frozen at clone time and never reconciled, so editing SCRUBJAY_MEMORY_REMOTE
# appeared to work and changed nothing — and a renamed bare repo stranded every push behind a
# dead path while the sync kept reporting success.
section "moving the remote re-points an existing clone"
rm -rf "$MEM"
OLD="$SANDBOX/old.git"; NEW="$SANDBOX/new.git"
seed_bare "$OLD"; seed_bare "$NEW"
sync "$OLD" pull >/dev/null 2>&1
assert_eq "cloned from the original remote" "$OLD" "$(git -C "$MEM" remote get-url origin)"
sync "$NEW" pull >/dev/null 2>&1
assert_eq "origin follows the config to the new remote" "$NEW" "$(git -C "$MEM" remote get-url origin)"

mkdir -p "$MEM/-home-user-moved"; echo moved > "$MEM/-home-user-moved/note.md"
sync "$NEW" push >/dev/null 2>&1
assert_eq "and the push lands in the NEW repo" \
  "1" "$(git --git-dir="$NEW" log --oneline main -- -home-user-moved 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "leaving the old one untouched" \
  "0" "$(git --git-dir="$OLD" log --oneline main -- -home-user-moved 2>/dev/null | wc -l | tr -d ' ')"

# ── the off switch still works ─────────────────────────────────────────────────────────────────
section "memory sync stays off when no remote is configured"
rm -rf "$MEM"
sync "" pull >/dev/null 2>&1
assert_no_file "no repo is created without a remote" "$MEM/.git/HEAD"

finish
