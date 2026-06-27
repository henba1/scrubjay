#!/usr/bin/env bash
# Transcript backend: local copy. For the box that has the NAS mounted (the receiver) —
# no network hop, no rsync-to-self. Set DOTCLAUDE_LOCAL_CHATS to the NAS chats root, e.g.
#   DOTCLAUDE_TRANSCRIPT_BACKEND="local"
#   DOTCLAUDE_LOCAL_CHATS="/mnt/nas1/Claude-Code-chats"
# Best-effort; never fails the session.
transport_ship() {  # transport_ship <src> <relpath> [mirror]   (src may be a file or a directory)
  local src="$1" relpath="$2" mode="${3:-}" root="${DOTCLAUDE_LOCAL_CHATS:-}"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "local: DOTCLAUDE_LOCAL_CHATS unset or missing ('$root') — backend inactive" >&2
    return 0
  fi
  local dst="$root/$relpath" d b
  if [ -d "$src" ]; then                       # directory: mirror its contents into <root>/<relpath>/
    mkdir -p "$dst" 2>/dev/null || return 0
    if [ "$mode" = mirror ]; then              # authoritative: drop dest entries not in src (flat dir)
      for d in "$dst"/*; do
        [ -e "$d" ] || continue; b="$(basename "$d")"
        [ -e "$src/$b" ] || rm -rf -- "$d" 2>/dev/null || true
      done
    fi
    cp -a "$src/." "$dst/" 2>/dev/null || true
  elif [ -f "$src" ]; then                     # file: place at <root>/<relpath>
    mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0
    cp -f "$src" "$dst" 2>/dev/null || true
  fi
}
