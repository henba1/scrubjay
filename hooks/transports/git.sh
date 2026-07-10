#!/usr/bin/env bash
# Transcript backend: git. Copy the transcript into the scrubjay-chats clone and push it.
# Requires SCRUBJAY_CHATS (a clone of the private relay repo). Best-effort; never fails.
transport_ship() {  # transport_ship <src> <relpath> [mirror]   (src may be a file or a directory)
  local src="$1" relpath="$2" mode="${3:-}" chats d b
  chats="$(sj_chats)"
  [ -n "$chats" ] && [ -d "$chats/.git" ] || return 0
  local dst="$chats/$relpath"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    if [ "$mode" = mirror ]; then              # authoritative: drop dest entries not in src (flat dir)
      for d in "$dst"/*; do
        [ -e "$d" ] || continue; b="$(basename "$d")"
        [ -e "$src/$b" ] || rm -rf -- "$d" 2>/dev/null || true
      done
    fi
    cp -a "$src/." "$dst/"
  else
    mkdir -p "$(dirname "$dst")"; cp -f "$src" "$dst"
  fi
  # Return the commit+push result (0 = relayed or already up to date) so a broken relay surfaces
  # via ship-transcript.sh's breadcrumb. Never aborts the caller — it's not `set -e`.
  (
    cd "$chats" || exit 0
    git add "$relpath" 2>/dev/null
    git diff --cached --quiet -- "$relpath" 2>/dev/null && exit 0   # unchanged -> no commit
    git commit -q -m "relay: $relpath" -- "$relpath" 2>/dev/null || exit 1
    if ! timeout 30 git push -q 2>/dev/null; then
      if [ -z "$(git status --porcelain 2>/dev/null | grep -v "$relpath")" ]; then
        timeout 30 git pull --rebase -q 2>/dev/null && timeout 30 git push -q 2>/dev/null && exit 0
      fi
      exit 1
    fi
  ) >/dev/null 2>&1
}
