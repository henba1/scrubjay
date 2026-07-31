#!/usr/bin/env bash
# bin/sj-doctor.sh — the health seam. Its whole job is to turn a silently degraded machine into a
# loudly degraded one, so the tests that matter are the ones proving it FAILS when it should.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

git config --global user.email "test@scrubjay.invalid"
git config --global user.name  "scrubjay tests"

doctor() { bash "$APP/bin/sj-doctor.sh" 2>&1; }

section "a sound machine passes and exits 0"
check "exits 0 when the local archive is present and writable" bash "$APP/bin/sj-doctor.sh" --quiet
assert_contains "reports healthy" "$(doctor)" "healthy"

section "a broken relay is reported, not swallowed"
mv "$SCRUBJAY_LOCAL_CHATS" "$SANDBOX/archive-unmounted"     # NAS not mounted
out="$(doctor)"; rc=0; bash "$APP/bin/sj-doctor.sh" --quiet >/dev/null 2>&1 || rc=$?
assert_contains "names the missing archive path" "$out" "archive path missing"
assert_eq "and exits non-zero" "1" "$rc"
mv "$SANDBOX/archive-unmounted" "$SCRUBJAY_LOCAL_CHATS"

section "an unknown backend is refused rather than assumed"
out="$(SCRUBJAY_TRANSCRIPT_BACKEND=nonsense doctor)"
assert_contains "flags the bad value" "$out" "unknown transcript backend"

# ── the memory failures that went unnoticed for weeks ──────────────────────────────────────────
BARE="$SANDBOX/mem.git"; MEM="$SANDBOX/memory"
git init -q --bare -b main "$BARE"
git clone -q "$BARE" "$MEM" 2>/dev/null
git -C "$MEM" symbolic-ref HEAD refs/heads/main
echo hello > "$MEM/note.md"; git -C "$MEM" add -A; git -C "$MEM" commit -q -m first
git -C "$MEM" push -q origin main

section "a healthy memory setup passes"
out="$(SCRUBJAY_MEMORY="$MEM" SCRUBJAY_MEMORY_REMOTE="$BARE" doctor)"
assert_contains "confirms the branch" "$out" "on branch main"
assert_contains "confirms nothing is unpublished" "$out" "no unpublished memory commits"

section "a clone on the wrong branch is caught"
git -C "$MEM" branch -m main master 2>/dev/null
out="$(SCRUBJAY_MEMORY="$MEM" SCRUBJAY_MEMORY_REMOTE="$BARE" doctor)"
assert_contains "names the branch mismatch" "$out" "but the archive uses main"
git -C "$MEM" branch -m master main 2>/dev/null

section "a clone pointing at a stale remote is caught"
out="$(SCRUBJAY_MEMORY="$MEM" SCRUBJAY_MEMORY_REMOTE="$SANDBOX/moved.git" doctor)"
assert_contains "reports the origin mismatch" "$out" "!= configured"

section "commits that never reached the archive are caught"
echo more > "$MEM/note2.md"; git -C "$MEM" add -A; git -C "$MEM" commit -q -m unpublished
out="$(SCRUBJAY_MEMORY="$MEM" SCRUBJAY_MEMORY_REMOTE="$BARE" doctor)"
assert_contains "counts the unpublished commits" "$out" "never published"

section "memory sync being off is informational, not a failure"
out="$(SCRUBJAY_MEMORY_REMOTE="" doctor)"
assert_contains "says it is off" "$out" "memory sync is off"
check "and does not fail the run" bash -c 'SCRUBJAY_MEMORY_REMOTE="" bash "$1/bin/sj-doctor.sh" --quiet' _ "$APP"

section "it is read-only"
# An agent may run this unprompted, so it must never mutate a repo.
before="$(git -C "$MEM" rev-parse HEAD)$(git --git-dir="$BARE" rev-parse main)"
SCRUBJAY_MEMORY="$MEM" SCRUBJAY_MEMORY_REMOTE="$BARE" doctor >/dev/null 2>&1
assert_eq "neither the clone nor the archive moved" \
  "$before" "$(git -C "$MEM" rev-parse HEAD)$(git --git-dir="$BARE" rev-parse main)"

finish
