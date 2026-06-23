#!/usr/bin/env bash
# Apply shared + host-specific Claude config into ~/.claude.
#   - symlinks  <app>/hooks  and  <data>/claude-md/{CLAUDE.md,commands,agents}
#   - merges    <data>/settings/settings.base.json + <data>/hosts/<host>/claude/settings.json
#     into ~/.claude/settings.json (a real file, arrays unioned)
# Idempotent. Backs up real (non-symlink) targets only with --force.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FORCE=0; HOST=""

usage() { echo "usage: claude-sync.sh [--host NAME] [--force]"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) CLAUDE_HOST="${2:?}"; export CLAUDE_HOST; shift 2;;
    --force) FORCE=1; shift;;
    -h|--help) usage 0;;
    *) echo "unknown arg: $1" >&2; usage 1;;
  esac
done

HOST="$(dc_host)"
DATA="$(dc_data)"
HOSTDIR="$DATA/hosts/$HOST"
[ -d "$HOSTDIR" ] || {
  echo "ERROR: no host dir '$HOSTDIR'." >&2
  echo "Register it first:  bin/claude-register-host.sh --host $HOST" >&2
  exit 1
}

mkdir -p "$CLAUDE_DIR"
echo "host: $HOST  ->  $CLAUDE_DIR   (data: $DATA)"

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
link "$DATA/claude-md/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
link "$DATA/claude-md/commands"  "$CLAUDE_DIR/commands"
link "$DATA/claude-md/agents"    "$CLAUDE_DIR/agents"
link "$APP/hooks"                "$CLAUDE_DIR/hooks"

echo "merging settings:"
BASE="$DATA/settings/settings.base.json"
OVER="$HOSTDIR/claude/settings.json"
OUT="$CLAUDE_DIR/settings.json"
[ -f "$OVER" ] && OVERJSON="$(cat "$OVER")" || OVERJSON='{}'
tmp="$(mktemp)"
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

echo "done. (templates/ and memory/ in the data repo are pull-on-demand — see README)"
