#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik. See LICENSE.

# bin/onboard-receiver.sh — provisioning the box that HOLDS the archive, and letting clients in.
#
# The authorize path is the part worth testing hard: it edits ~/.ssh/authorized_keys, it is what
# a human runs on the receiver, and getting it wrong locks you out of your own archive or — worse
# — quietly breaks a key that already worked.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

RX="$APP/bin/onboard-receiver.sh"
AK="$HOME/.ssh/authorized_keys"
# GNU vs BSD stat — same shape as the shims at the top of bin/lib.sh (tests must pass on macOS too).
mode() { stat -c%a "$1" 2>/dev/null || stat -f%Lp "$1" 2>/dev/null; }
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTestsOnly000000000000000 laptop relay"
mkdir -p "$SANDBOX/keys"; printf '%s\n' "$KEY" > "$SANDBOX/keys/relay.pub"

section "provisioning is unprivileged and idempotent"
ROOT="$SANDBOX/archive-root"
check "creates the archive root without sudo" bash "$RX" --path "$ROOT"
check "the root exists afterwards" test -d "$ROOT"
check "re-running is a no-op, not an error" bash "$RX" --path "$ROOT"
before="$(ls -a "$ROOT" | sort)"
check "--print changes nothing" bash "$RX" --print --path "$SANDBOX/never-created"
assert_no_file "--print did not create the root" "$SANDBOX/never-created"
assert_eq "and left an existing root alone" "$before" "$(ls -a "$ROOT" | sort)"

section "authorize pins each role to one verb"
check "relay key accepted" bash "$RX" --path "$ROOT" --authorize relay "$SANDBOX/keys/relay.pub"
assert_contains "relay gets the append-only forced command" "$(cat "$AK")" "bin/sj-receive.sh $ROOT"
assert_contains "and restrict" "$(cat "$AK")" ",restrict"
check "memory key accepted" bash "$RX" --path "$ROOT" --authorize memory "$SANDBOX/keys/relay.pub"
assert_contains "memory gets git-shell" "$(cat "$AK")" 'git-shell -c'
check "mcp key accepted" bash "$RX" --path "$ROOT" --authorize mcp "$SANDBOX/keys/relay.pub"
assert_contains "mcp gets the read-only server" "$(cat "$AK")" "bin/sjmcp-serve.sh"
check_fails "an unknown role is refused" bash "$RX" --path "$ROOT" --authorize wheel "$SANDBOX/keys/relay.pub"

section "it cannot corrupt a key that already worked"
# The real-world failure: authorized_keys not ending in a newline, so an appended line splices
# onto the previous key and breaks BOTH. `tee -a` by hand does exactly this.
printf 'ssh-ed25519 AAAAPreexistingKey000000000000000000000 already-here' > "$AK"   # NO trailing newline
check "authorize onto a file with no trailing newline" bash "$RX" --path "$ROOT" --authorize relay "$SANDBOX/keys/relay.pub"
assert_eq "the pre-existing key is still on its own line" \
  "1" "$(grep -c '^ssh-ed25519 AAAAPreexistingKey' "$AK")"
assert_eq "and the new line is separate" "2" "$(wc -l < "$AK" | tr -d ' ')"

section "authorizing the same key twice does not duplicate it"
n1="$(wc -l < "$AK")"
check "second authorize succeeds" bash "$RX" --path "$ROOT" --authorize relay "$SANDBOX/keys/relay.pub"
assert_eq "no extra line was added" "$n1" "$(wc -l < "$AK" | tr -d ' ')"

section "it refuses input that would leak or break things"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nnope\n' > "$SANDBOX/keys/id_ed25519"
check_fails "a PRIVATE key is refused outright" bash "$RX" --path "$ROOT" --authorize relay "$SANDBOX/keys/id_ed25519"
assert_eq "and nothing was written" "$n1" "$(wc -l < "$AK" | tr -d ' ')"
check_fails "a nonexistent key file is refused" bash "$RX" --path "$ROOT" --authorize relay "$SANDBOX/keys/absent.pub"
printf 'not a key at all\n' > "$SANDBOX/keys/junk.pub"
check_fails "junk is refused" bash "$RX" --path "$ROOT" --authorize relay "$SANDBOX/keys/junk.pub"

section "permissions sshd will actually accept"
assert_eq "authorized_keys is 600" "600" "$(mode "$AK")"
assert_eq "~/.ssh is 700" "700" "$(mode "$HOME/.ssh")"

finish
