#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The rsync-wg relay must be able to REPLACE what it shipped before, not just create it.
#
# Every session ships the same paths again (the transcript, its lease, history.jsonl, the readable
# copy), so a relay that can only create files works exactly once per path and then fails every
# time after — while the doctor's "key accepted" probe stays green. Seen in the field: a newer rsync
# sender against an older receiver behind `rrsync -wo` rejects file-to-file replacement (exit 23),
# while file-into-directory works. The stub rsync below models exactly that receiver.
#
# Also pinned here, because they hid the failure during onboarding:
#   - onboard.sh keeps the documented RECV_* / WG_KEY presets instead of wiping them;
#   - SessionStart probes the CURRENT relay/memory target, not a stale one onboarding recorded.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

RECV="$SANDBOX/receiver"; mkdir -p "$RECV" "$SANDBOX/stubbin"
# rsync stub: last two args are <src> <target:dest>. Copies into $RECV. File-to-file onto an
# existing file fails with 23, like the real receiver did; everything else succeeds.
cat > "$SANDBOX/stubbin/rsync" <<'EOF'
#!/usr/bin/env bash
src="${@: -2:1}"; dst="${@: -1}"; dst="${dst#*:}"
printf '%s\n' "$dst" >> "$SANDBOX/rsync.calls"
case "$dst" in
  */) mkdir -p "$RECV/$dst" && cp "$src" "$RECV/$dst" ;;
  *)  [ -e "$RECV/$dst" ] && { echo "could not make way for new regular file" >&2; exit 23; }
      mkdir -p "$(dirname "$RECV/$dst")" && cp "$src" "$RECV/$dst" ;;
esac
EOF
chmod +x "$SANDBOX/stubbin/rsync"
export PATH="$SANDBOX/stubbin:$PATH" RECV SCRUBJAY_WG_TARGET="rx@receiver.invalid"
. "$APP/hooks/transports/rsync-wg.sh"

section "a file is shipped into its directory, so it can be replaced"
f="$SANDBOX/history.jsonl"; echo one > "$f"
check "first ship creates it"   transport_ship "$f" "testhost/history.jsonl"
echo two > "$f"
check "second ship replaces it" transport_ship "$f" "testhost/history.jsonl"
assert_eq "the receiver holds the new content" "two" "$(cat "$RECV/testhost/history.jsonl")"
assert_eq "the destination given to rsync is the directory" "testhost/" "$(tail -1 "$SANDBOX/rsync.calls")"

section "a source with another name is staged under its destination name"
tmp="$(mktemp)"; echo readable > "$tmp"
check "ships under the destination name" transport_ship "$tmp" "testhost/readable/proj/2026-01-01_topic__abcd1234.md"
assert_file "it arrives with that name" "$RECV/testhost/readable/proj/2026-01-01_topic__abcd1234.md"
assert_no_file "not under the temp file's name" "$RECV/testhost/readable/proj/$(basename "$tmp")"
check "and replaces it later, too" transport_ship "$tmp" "testhost/readable/proj/2026-01-01_topic__abcd1234.md"
check "the source is left alone" test -f "$tmp"
rm -f "$tmp"

section "a failed transfer is still reported"
cat > "$SANDBOX/stubbin/rsync" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
check_fails "a refusing receiver is a failure, not a silent success" transport_ship "$f" "testhost/history.jsonl"

section "onboarding keeps the documented presets"
# The relay block resets its own variables before prompting; it must default them, not wipe them.
blk="$(sed -n '/^# backend-specific settings/,/^case "\$BACKEND" in/p' "$APP/bin/onboard.sh")"
out="$(RECV_USER=preset-user RECV_HOST=preset-host RECV_PORT=2222 RECV_PATH=/preset/root WG_KEY=/preset/key \
       bash -c "$(printf '%s\n' "$blk" | sed '$d'); "'printf "%s|%s|%s|%s|%s" "$RECV_USER" "$RECV_HOST" "$RECV_PORT" "$RECV_PATH" "$WG_KEY"')"
assert_eq "RECV_* and WG_KEY survive to the prompts" "preset-user|preset-host|2222|/preset/root|/preset/key" "$out"

section "SessionStart probes the configured target, not a stale recorded one"
cat > "$SANDBOX/stubbin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "rx@receiver.invalid" ] && exit 1; done   # authorized: forced command refuses `true`
exit 255                                                              # anything else: not authorized
EOF
chmod +x "$SANDBOX/stubbin/ssh"
sj_record_pending relay ssh "default-user@receiver.invalid"
out="$(bash "$APP/hooks/sync-session.sh" </dev/null 2>/dev/null)"
assert_contains "a working configured relay reads as authorized" "$out" "now authorized on the transcript receiver"
assert_no_file "and the stale wait clears" "$(sj_pending_file)"

finish
