#!/usr/bin/env bash
# Transcript backend: git. Copy the transcript into the claude-chats clone and push it.
# Requires DOTCLAUDE_CHATS (a clone of the private relay repo). Best-effort; never fails.
transport_ship() {  # transport_ship <src> <relpath>   (src may be a file or a directory)
  local src="$1" relpath="$2" chats
  chats="$(dc_chats)"
  [ -n "$chats" ] && [ -d "$chats/.git" ] || return 0
  local dst="$chats/$relpath"
  if [ -d "$src" ]; then
    mkdir -p "$dst"; cp -a "$src/." "$dst/"
  else
    mkdir -p "$(dirname "$dst")"; cp -f "$src" "$dst"
  fi
  (
    cd "$chats" || exit 0
    git add "$relpath" 2>/dev/null
    git diff --cached --quiet -- "$relpath" 2>/dev/null && exit 0   # unchanged -> no commit
    git commit -q -m "relay: $relpath" -- "$relpath" 2>/dev/null || exit 0
    if ! timeout 30 git push -q 2>/dev/null; then
      if [ -z "$(git status --porcelain 2>/dev/null | grep -v "$relpath")" ]; then
        timeout 30 git pull --rebase -q 2>/dev/null && timeout 30 git push -q 2>/dev/null
      fi
    fi
  ) >/dev/null 2>&1 || true
}
