#!/usr/bin/env bash
# Onboard a new machine: scaffold hosts/<host>/ from the template, prefill detected
# facts, pin the stable host name, and build the chat index.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST=""
[ "${1:-}" = "--host" ] && { HOST="${2:?}"; shift 2; }
HOST="${HOST:-${CLAUDE_HOST:-$(hostname -s)}}"
DST="$REPO/hosts/$HOST"

if [ -e "$DST" ]; then
  echo "host '$HOST' already exists at $DST (leaving as-is)"
else
  cp -r "$REPO/hosts/_template" "$DST"
  OS="$(uname -s -r)"
  # Prefill the detected facts in env.md (use | as sed delim to survive / in paths).
  sed -i \
    -e "s|{{HOST}}|$HOST|g" \
    -e "s|{{OS}}|$OS|g" \
    -e "s|{{HOME}}|$HOME|g" \
    "$DST/env.md"
  echo "created $DST  (edit env.md to fill in the rest)"
fi

# Pin the stable host name so sync/index don't pick up transient hostnames.
mkdir -p "$HOME/.config/dotclaude"
echo "$HOST" > "$HOME/.config/dotclaude/host"
echo "pinned host name -> ~/.config/dotclaude/host = $HOST"

"$REPO/bin/claude-index-chats.sh" --host "$HOST"
echo "next: review hosts/$HOST/, then run bin/claude-sync.sh"
