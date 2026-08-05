#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# "Not yet authorized on the receiver" as a first-class, self-clearing state.
#
# On the p2p backends a new machine cannot authorize itself — a human with root on the receiver
# must paste its key. So every fresh host spends its early life in a state where sync is correctly
# configured and publishes nothing. These tests pin that the state is recorded, reported while it
# lasts, and closed out automatically (including the catch-up publish) the moment it ends.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

git config --global user.email "test@scrubjay.invalid"
git config --global user.name  "scrubjay tests"

PF="$(sj_pending_file)"

section "the wait is recorded, one line per subsystem, idempotently"
sj_record_pending memory git "$SANDBOX/nope.git"
assert_file "a pending file is written" "$PF"
assert_contains "it names the subsystem and probe" "$(cat "$PF")" "memory	git"
sj_record_pending relay ssh "user@receiver.invalid"
assert_eq "two subsystems can wait at once" "2" "$(wc -l < "$PF" | tr -d ' ')"
sj_record_pending memory git "$SANDBOX/moved.git"
assert_eq "re-recording replaces rather than duplicates" "2" "$(wc -l < "$PF" | tr -d ' ')"
assert_contains "and keeps the newest target" "$(cat "$PF")" "moved.git"

section "clearing removes only that subsystem, and the file when nothing is left"
sj_clear_pending memory
assert_eq "one entry remains" "1" "$(wc -l < "$PF" | tr -d ' ')"
assert_contains "the right one" "$(cat "$PF")" "relay"
sj_clear_pending relay
assert_no_file "the file goes away once nothing is pending" "$PF"

section "the probe distinguishes authorized from not"
BARE="$SANDBOX/real.git"; git init -q --bare -b main "$BARE"
check "a reachable git remote reads as authorized" sj_pending_authorized git "$BARE"
check_fails "a missing one does not" sj_pending_authorized git "$SANDBOX/absent.git"

# ── the loop that used to be left to the user ──────────────────────────────────────────────────
section "SessionStart publishes what accumulated, the moment authorization lands"
MEM="$SANDBOX/memory"; LATER="$SANDBOX/later.git"
export SCRUBJAY_MEMORY="$MEM" SCRUBJAY_MEMORY_REMOTE="$LATER"
# Onboarding state: remote refuses us, so memory-sync falls back to a local repo and commits there.
mkdir -p "$MEM"; bash "$APP/bin/memory-sync.sh" pull >/dev/null 2>&1
mkdir -p "$MEM/-home-user-proj"; echo "written while unauthorized" > "$MEM/-home-user-proj/note.md"
bash "$APP/bin/memory-sync.sh" push >/dev/null 2>&1
sj_record_pending memory git "$LATER"
assert_eq "the memory is committed but unpublished" \
  "1" "$(git -C "$MEM" log --oneline -- -home-user-proj 2>/dev/null | wc -l | tr -d ' ')"

out="$(bash "$APP/hooks/sync-session.sh" </dev/null 2>/dev/null)"
assert_contains "while unauthorized, SessionStart says so plainly" "$out" "NOT yet authorized"
assert_file "and the wait is still recorded" "$PF"

# The human pastes the key on the receiver — modelled here as the remote coming into existence.
git init -q --bare -b main "$LATER"
out="$(bash "$APP/hooks/sync-session.sh" </dev/null 2>/dev/null)"
assert_contains "the next session reports it went live" "$out" "now authorized"
assert_eq "and the stranded memory was published without being asked" \
  "1" "$(git --git-dir="$LATER" log --oneline main -- -home-user-proj 2>/dev/null | wc -l | tr -d ' ')"
assert_no_file "the pending state clears itself" "$PF"

section "a host with nothing pending is unaffected"
out="$(bash "$APP/hooks/sync-session.sh" </dev/null 2>/dev/null)"
assert_contains "no authorization chatter" "$out" ""
case "$out" in *"NOT yet authorized"*) _no "stays quiet once cleared" "still reporting a pending wait" ;; *) _ok "stays quiet once cleared" ;; esac

finish
