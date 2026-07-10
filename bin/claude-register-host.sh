#!/usr/bin/env bash
# Onboard a new machine: scaffold <data>/hosts/<host>/ from the app skeleton, prefill
# detected facts, pin the stable host name, and build the chat index.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
[ "${1:-}" = "--host" ] && { CLAUDE_HOST="${2:?}"; export CLAUDE_HOST; shift 2; }
HOST="$(sj_host)"
DATA="$(sj_data)"
DST="$DATA/hosts/$HOST"

if [ -e "$DST" ]; then
  echo "host '$HOST' already exists at $DST (leaving as-is)"
else
  mkdir -p "$DATA/hosts"
  cp -r "$APP/skeleton/host" "$DST"
  OS="$(uname -s -r)"
  sed -i -e "s|{{HOST}}|$HOST|g" -e "s|{{OS}}|$OS|g" -e "s|{{HOME}}|$HOME|g" "$DST/env.md"
  echo "created $DST  (edit env.md to fill in the rest)"
fi

mkdir -p "$HOME/.config/scrubjay"
echo "$HOST" > "$HOME/.config/scrubjay/host"
echo "pinned host name -> ~/.config/scrubjay/host = $HOST"

"$APP/bin/claude-index-chats.sh" --host "$HOST"
echo "next: review $DST/, then run bin/claude-sync.sh"
