#!/usr/bin/env bash
# Transcript backend: local copy. For the box that has the NAS mounted (the receiver) —
# no network hop, no rsync-to-self. Set DOTCLAUDE_LOCAL_CHATS to the NAS chats root, e.g.
#   DOTCLAUDE_TRANSCRIPT_BACKEND="local"
#   DOTCLAUDE_LOCAL_CHATS="/media/hendrik/NAS1/Claude-Code-chats"
# Best-effort; never fails the session.
transport_ship() {  # transport_ship <src> <relpath>
  local src="$1" relpath="$2" root="${DOTCLAUDE_LOCAL_CHATS:-}"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "local: DOTCLAUDE_LOCAL_CHATS unset or missing ('$root') — backend inactive" >&2
    return 0
  fi
  local dst="$root/$relpath"
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0
  cp -f "$src" "$dst" 2>/dev/null || true
}
