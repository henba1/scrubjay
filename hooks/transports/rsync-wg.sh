#!/usr/bin/env bash
# UPCOMING transcript backend: peer-to-peer rsync over a WireGuard tunnel to a home
# login node — no third-party server in the path. NOT yet active; see
# docs/transcript-transport.md. To switch: set in ~/.config/dotclaude/config
#   DOTCLAUDE_TRANSCRIPT_BACKEND="rsync-wg"
#   DOTCLAUDE_WG_TARGET="claude@home.example.net:/srv/claude-chats"   # reachable over WG
#   DOTCLAUDE_WG_SSHKEY="$HOME/.ssh/claude_transcripts_ed25519"        # per-machine key
transport_ship() {  # transport_ship <src> <relpath>   (src may be a file or a directory)
  local src="$1" relpath="$2"
  if [ -z "${DOTCLAUDE_WG_TARGET:-}" ]; then
    echo "rsync-wg: DOTCLAUDE_WG_TARGET unset — backend inactive" >&2; return 0
  fi
  local key="${DOTCLAUDE_WG_SSHKEY:-$HOME/.ssh/id_ed25519}"
  local ssh="ssh -i $key -o StrictHostKeyChecking=accept-new"
  # --mkpath creates the parent path on the receiver; tunnel must be up.
  if [ -d "$src" ]; then                       # directory: trailing slashes mirror contents into <relpath>/
    rsync -a --mkpath -e "$ssh" "$src/" "$DOTCLAUDE_WG_TARGET/$relpath/" 2>/dev/null || true
  else
    rsync -a --mkpath -e "$ssh" "$src" "$DOTCLAUDE_WG_TARGET/$relpath" 2>/dev/null || true
  fi
}
