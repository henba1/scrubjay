#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Notifications (bin/sj-notify.sh, called from bin/sj-live.sh). What must hold: a bell when a turn
# ends or stops at a permission prompt and at no other change, nothing at all while it is off, and
# never a byte on stdout, which on some hook events is the model's context.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
export SCRUBJAY_RUN_DIR="$SANDBOX/run" SJ_NOTIFY_DEV="$SANDBOX/tty" SCRUBJAY_LIVE_PID=$$
S=11111111-2222-4333-8444-555555555555
: > "$SJ_NOTIFY_DEV"
rings() { sj_size "$SJ_NOTIFY_DEV"; }
# The bell is rung detached; give it a moment to land.
settle() { local _; for _ in $(seq 30); do [ "$(rings)" -ge "$1" ] && break; sleep 0.1; done; sleep 0.3; }
mark() { bash "$APP/bin/sj-live.sh" mark "$S" "$1" /w; }
. "$APP/bin/lib.sh"

section "sj-notify.sh rings the terminal it is pointed at"
out="$(bash "$APP/bin/sj-notify.sh" $$)"
assert_eq "one bell" "$(printf '\a')" "$(cat "$SJ_NOTIFY_DEV")"
assert_eq "and nothing on stdout" "" "$out"
: > "$SJ_NOTIFY_DEV"
bash "$APP/bin/sj-notify.sh" 'x;y'; bash "$APP/bin/sj-notify.sh"
assert_eq "not a process id: nothing" 0 "$(rings)"
check "a terminal it cannot write: still exits 0" env SJ_NOTIFY_DEV="$SANDBOX/no/such" bash "$APP/bin/sj-notify.sh" $$

section "on: a turn ending or stopping for a permission rings, nothing else does"
export SCRUBJAY_NOTIFY=on
mark idle; mark working          # a session starting, a turn starting: 0
mark idle                        # the turn ends: 1
mark working; mark waiting       # a permission prompt: 2
mark idle                        # granted, the turn ran on and ended: 3
mark idle                        # idle again: still 3
settle 3
assert_eq "three bells" 3 "$(rings)"
mark ended; settle 4
assert_eq "a session ending: none" 3 "$(rings)"

section "off: nothing"
for v in off "" yes; do
  : > "$SJ_NOTIFY_DEV"
  SCRUBJAY_NOTIFY="$v" mark working; SCRUBJAY_NOTIFY="$v" mark idle; settle 1
  assert_eq "SCRUBJAY_NOTIFY='$v'" 0 "$(rings)"
done

section "the hooks stay silent"
export SCRUBJAY_NOTIFY=on
mark working
out="$(printf '{"session_id":"%s","hook_event_name":"PermissionRequest","cwd":"/w"}' "$S" | bash "$APP/hooks/live-session.sh")"
assert_eq "PermissionRequest prints nothing" "" "$out"
assert_eq "and marks the session waiting" waiting "$(jq -r .state "$SCRUBJAY_RUN_DIR/live/$S.lease")"

section "sj-doctor"
d() { bash "$APP/bin/sj-doctor.sh" harnesses 2>&1; }
assert_contains "on: says so" "$(SCRUBJAY_NOTIFY=on d)" "notify: a bell when an agent finishes a turn"
assert_contains "off: suggests it" "$(SCRUBJAY_NOTIFY=off d)" "set SCRUBJAY_NOTIFY=on"
assert_contains "a bad value is a failure" "$(SCRUBJAY_NOTIFY=yes d)" "is not on or off"

finish
