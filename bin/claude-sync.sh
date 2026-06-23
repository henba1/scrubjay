#!/usr/bin/env bash
# Apply shared + host-specific Claude config into ~/.claude.
#   - symlinks claude-md/{CLAUDE.md,commands,agents} into ~/.claude
#   - merges settings/settings.base.json + hosts/<host>/claude/settings.json
#     into ~/.claude/settings.json (a real file, arrays unioned)
# Idempotent. Safe to re-run. Backs up real (non-symlink) targets only with --force.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FORCE=0
HOST=""

usage() { echo "usage: claude-sync.sh [--host NAME] [--force]"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2;;
    --force) FORCE=1; shift;;
    -h|--help) usage 0;;
    *) echo "unknown arg: $1" >&2; usage 1;;
  esac
done

resolve_host() {
  [ -n "$HOST" ] && { echo "$HOST"; return; }
  [ -n "${CLAUDE_HOST:-}" ] && { echo "$CLAUDE_HOST"; return; }
  [ -f "$HOME/.config/dotclaude/host" ] && { cat "$HOME/.config/dotclaude/host"; return; }
  hostname -s
}
HOST="$(resolve_host)"
HOSTDIR="$REPO/hosts/$HOST"
[ -d "$HOSTDIR" ] || {
  echo "ERROR: no host dir '$HOSTDIR'." >&2
  echo "Register it first:  bin/claude-register-host.sh --host $HOST" >&2
  exit 1
}

mkdir -p "$CLAUDE_DIR"
echo "host: $HOST  ->  $CLAUDE_DIR"

link() {  # link <src> <dst>
  local src="$1" dst="$2"
  [ -e "$src" ] || return 0
  if [ -L "$dst" ]; then
    [ "$(readlink "$dst")" = "$src" ] && { echo "  ok    $dst"; return 0; }
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    if [ "$FORCE" = 1 ]; then mv "$dst" "$dst.bak.$(date +%s)"; echo "  bak   $dst"
    else echo "  SKIP  $dst (real file; rerun with --force)"; return 0; fi
  fi
  ln -s "$src" "$dst"; echo "  link  $dst"
}

echo "symlinking scopes:"
link "$REPO/claude-md/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
link "$REPO/claude-md/commands"  "$CLAUDE_DIR/commands"
link "$REPO/claude-md/agents"    "$CLAUDE_DIR/agents"

echo "merging settings:"
BASE="$REPO/settings/settings.base.json"
OVER="$HOSTDIR/claude/settings.json"
[ -f "$OVER" ] || OVER=/dev/stdin   # fall back to empty object below
OUT="$CLAUDE_DIR/settings.json"
tmp="$(mktemp)"
if [ "$OVER" = /dev/stdin ]; then OVERJSON='{}'; else OVERJSON="$(cat "$OVER")"; fi
jq -n --argjson base "$(cat "$BASE")" --argjson host "$OVERJSON" '
  ($base * $host)
  | .permissions.allow = (($base.permissions.allow // []) + ($host.permissions.allow // []) | unique)
  | .permissions.deny  = (($base.permissions.deny  // []) + ($host.permissions.deny  // []) | unique)
' > "$tmp"
if [ -f "$OUT" ] && [ ! -L "$OUT" ] && ! cmp -s "$tmp" "$OUT"; then
  cp "$OUT" "$OUT.bak.$(date +%s)"; echo "  bak   $OUT"
fi
if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then echo "  ok    (unchanged)"; rm -f "$tmp"
else mv "$tmp" "$OUT"; echo "  wrote $OUT"; fi

echo "done. (templates/ and memory/ are pull-on-demand, not auto-applied — see README)"
