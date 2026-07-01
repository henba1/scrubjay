#!/usr/bin/env bash
# Transcript backend: peer-to-peer rsync over a WireGuard/SSH tunnel to the NAS receiver —
# no third-party server in the path. The receiver pins the destination via a forced
# command="rrsync -wo <root>" in authorized_keys, so paths sent here are RELATIVE to that
# root. (Sending an absolute /srv/... path makes rrsync re-root it *under* the root →
# double-nested; verified.) Config in ~/.config/dotclaude/config:
#   DOTCLAUDE_TRANSCRIPT_BACKEND="rsync-wg"
#   DOTCLAUDE_WG_TARGET="claude-rx@claude-receiver"   # ssh destination ONLY — no remote path
#   DOTCLAUDE_WG_SSHKEY="$HOME/.ssh/claude_transcripts_ed25519"
# Per-machine reachability (HostName/Port/User) lives in the ~/.ssh/config 'claude-receiver'
# alias, so this line stays identical on every machine.
transport_ship() {  # transport_ship <src> <relpath> [mirror]   (src may be a file or a directory)
  local src="$1" relpath="$2" mode="${3:-}"
  if [ -z "${DOTCLAUDE_WG_TARGET:-}" ]; then
    echo "rsync-wg: DOTCLAUDE_WG_TARGET unset — backend inactive" >&2; return 0
  fi
  local key="${DOTCLAUDE_WG_SSHKEY:-$HOME/.ssh/id_ed25519}"
  local ssh="ssh -i $key -o StrictHostKeyChecking=accept-new"
  # mirror: --delete makes the receiver dir an exact copy of src (drops renamed/stale plans). It
  #   rides the rrsync protocol so it works even with the write-only receiver; if rrsync refuses
  #   the option the whole rsync is a no-op (|| true), degrading to the old additive behaviour.
  local del=""; [ "$mode" = mirror ] && del="--delete"
  # --no-perms: don't clone the source's restrictive transcript mode onto the receiver. It does
  #   NOT widen perms (rsync stamps the dest at the source mode; a umask can only remove bits) —
  #   the receiver's dc-receive.sh forced-command wrapper is what chmods the archive
  #   group-readable after each push, so the human + MCP server can read it. relpath is relative
  #   to the receiver's rrsync root; --mkpath creates it.
  if [ -d "$src" ]; then                       # directory: trailing slashes mirror contents into <relpath>/
    rsync -a --no-perms --mkpath $del -e "$ssh" "$src/" "$DOTCLAUDE_WG_TARGET:$relpath/" 2>/dev/null || true
  else
    rsync -a --no-perms --mkpath -e "$ssh" "$src" "$DOTCLAUDE_WG_TARGET:$relpath" 2>/dev/null || true
  fi
}
