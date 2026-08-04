#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik. See LICENSE.

# Set up THIS box as the scrubjay archive host — the thing every other machine relays into.
#
# It is the one role that had no guided script: clients have onboard.sh / onboard-memory.sh /
# onboard-mcp-client.sh / onboard-hpc-client.sh, the edge has onboard-edge-node.sh, and the box
# actually holding the archive was a checklist in docs/memory-sync.md that you followed by hand.
#
#   bin/onboard-receiver.sh [--path DIR]           provision + report what is left (default)
#   bin/onboard-receiver.sh --authorize <role> <pubkey-file|->   let ONE client in
#   bin/onboard-receiver.sh --print                show, change nothing
#     roles:  relay   append-only transcript push   (rrsync -wo, via bin/sj-receive.sh)
#             memory  the cross-machine memory repo (git-shell)
#             mcp     read-only archive queries     (bin/sjmcp-serve.sh)
#
# ── what this does and does NOT do ────────────────────────────────────────────────────────────
# Everything here runs as YOU, unprivileged: a directory, a bare git repo, and lines in your own
# ~/.ssh/authorized_keys. That covers the whole storage role.
#
# It does NOT open the box up. Reachability — sshd, its port, the firewall, WireGuard, DDNS or a
# port-forward — needs root and usually the router, and is printed rather than applied. Same for
# mounting a disk (bin/sj-mount.sh) and snapshots (bin/sj-snapshot.sh). scrubjay is a sync tool
# that needs somewhere to put bytes, not a NAS appliance: it computes the exact command and
# explains it; you run anything privileged.
#
# The one deliberate constraint it preserves: a machine cannot authorize itself. --authorize runs
# HERE, by someone who already has access to this box. That is the same human step as before —
# it just gets the forced command right, and appends safely (a missing trailing newline in
# authorized_keys silently glues the new key onto the previous one and breaks both).
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT=""; MODE=provision; ROLE=""; KEYSRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --path)      ROOT="${2:-}"; shift ;;
    --print)     MODE=print ;;
    --authorize) MODE=authorize; ROLE="${2:-}"; KEYSRC="${3:-}"; shift 2 ;;
    -h|--help)   awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

# The archive root: an explicit --path, else what this box already serves, else under $HOME (which
# needs no root — a mounted disk is a separate, optional concern handled by bin/sj-mount.sh).
# SCRUBJAY_STORAGE_DIR names the directory itself, so a box set up by hand here matches one set up
# through onboard.sh's NAS flow.
[ -n "$ROOT" ] || ROOT="${SCRUBJAY_LOCAL_CHATS:-$HOME/${SCRUBJAY_STORAGE_DIR:-scrubjay-storage}}"

AK="$HOME/.ssh/authorized_keys"

# ── the forced command for each role ──────────────────────────────────────────────────────────
# Each key is pinned to exactly one verb: append, git, or read. `restrict` removes pty/forwarding/
# agent/X11, so a leaked key can do that one thing and nothing else.
role_command() {  # role_command <role> <root>
  case "$1" in
    relay)  printf 'command="%s/bin/sj-receive.sh %s",restrict' "$APP" "$2" ;;
    memory) printf 'command="git-shell -c \\"$SSH_ORIGINAL_COMMAND\\"",restrict' ;;
    mcp)    printf 'command="%s/bin/sjmcp-serve.sh",restrict' "$APP" ;;
    *) return 1 ;;
  esac
}

# ── authorize one client ──────────────────────────────────────────────────────────────────────
if [ "$MODE" = authorize ]; then
  cmd="$(role_command "$ROLE" "$ROOT")" || die "unknown role '$ROLE' (use: relay, memory, mcp)"
  [ -n "$KEYSRC" ] || die "give a public key file, or - to read stdin"
  if [ "$KEYSRC" = - ]; then key="$(cat)"; else
    [ -f "$KEYSRC" ] || die "no such file: $KEYSRC"
    key="$(cat "$KEYSRC")"
  fi
  key="$(printf '%s' "$key" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *) ;;
    *) die "that does not look like an SSH public key (did you pass a PRIVATE key by mistake?)" ;;
  esac
  case "$key" in *PRIVATE*) die "refusing: that is a PRIVATE key. Send me the .pub." ;; esac

  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [ -f "$AK" ] || { : > "$AK"; }
  chmod 600 "$AK"
  keybody="$(printf '%s' "$key" | awk '{print $1" "$2}')"     # type+base64, ignoring the comment
  if grep -qF "$keybody" "$AK" 2>/dev/null && grep -qF "$cmd" "$AK" 2>/dev/null; then
    ok "already authorized for '$ROLE' — nothing to do"; exit 0
  fi
  # A file not ending in a newline would splice this line onto the previous key and break BOTH.
  # Observed in the wild; this is the whole reason not to do it with `tee -a` by hand.
  [ -s "$AK" ] && [ "$(tail -c1 "$AK" | wc -l)" -eq 0 ] && printf '\n' >> "$AK"
  printf '%s %s\n' "$cmd" "$key" >> "$AK" || die "could not write $AK"
  ok "authorized for '$ROLE' in $(sj_pretty_path "$AK")"
  info "that key may now ONLY: $(case "$ROLE" in relay) echo 'append to the archive';; memory) echo 'run git against the memory repo';; mcp) echo 'read the archive';; esac)"
  exit 0
fi

# ── provision ─────────────────────────────────────────────────────────────────────────────────
echo; info "scrubjay receiver setup on '$(sj_host)'  (archive root: $ROOT)"
[ "$MODE" = print ] && info "--print: reporting only, changing nothing"

if [ -d "$ROOT" ]; then ok "archive root exists: $ROOT"
elif [ "$MODE" = print ]; then info "would create: $ROOT"
else
  mkdir -p "$ROOT" && chmod 2775 "$ROOT" 2>/dev/null \
    && ok "created $ROOT (setgid, so pushes inherit the group that reads them)" \
    || die "could not create $ROOT"
fi
[ -w "$ROOT" ] || warn "$ROOT is not writable by you — pushes will fail"

# The memory bare repo is onboard-memory.sh's job; don't duplicate the hook here, just check.
if [ -d "$ROOT/memory.git" ]; then ok "memory repo present: $ROOT/memory.git"
else info "no memory repo yet — run bin/onboard-memory.sh on this box (it owns that step)"; fi

# Tools each role needs, reported per role so a partial setup is legible.
echo; info "what each role needs here:"
if command -v rrsync >/dev/null 2>&1 || [ -x /usr/share/doc/rsync/scripts/rrsync ]; then
  ok "relay:  rrsync present"
else
  warn "relay:  rrsync MISSING — ships with rsync on Debian/Ubuntu (sudo apt install rsync), or copy"
  warn "        its scripts/rrsync into your PATH. Without it the transcript relay cannot land."
fi
command -v git-shell >/dev/null 2>&1 && ok "memory: git-shell present" \
  || warn "memory: git-shell MISSING — it ships with git (sudo apt install git)"
command -v uv >/dev/null 2>&1 && ok "mcp:    uv present" \
  || warn "mcp:    uv MISSING — needed only to serve archive queries (https://astral.sh/uv)"

# ── what is left, and who has to do it ────────────────────────────────────────────────────────
echo; info "Let a machine in — run HERE, once per client key (a machine must not authorize itself):"
echo
echo "    bin/onboard-receiver.sh --authorize relay  <client-relay.pub>"
echo "    bin/onboard-receiver.sh --authorize memory <client-memory.pub>"
echo "    bin/onboard-receiver.sh --authorize mcp    <client-mcp.pub>"
echo
info "Each client prints its own public key at the end of its onboarding. Copy the .pub here"
info "(it is public — mail it, paste it, whatever), then run the line above."

echo; info "Still yours, because they need root and/or the router:"
echo "    • sshd reachable from your other machines (port, ListenAddress, and the firewall)"
echo "    • how peers reach this box: WireGuard, or a port-forward + DDNS for anything off-LAN"
echo "    • a disk, if the archive should not live on this one:  bin/sj-mount.sh"
echo "    • point-in-time history of the archive:                bin/sj-snapshot.sh --schedule"
echo
info "Then, from a client:  bin/sj-doctor.sh    (it will say whether this box is reachable)"
