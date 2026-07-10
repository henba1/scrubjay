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

usage() { echo "usage: claude-sync.sh [--host NAME] [--force] [--version]"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) CLAUDE_HOST="${2:?}"; export CLAUDE_HOST; shift 2;;
    --force) FORCE=1; shift;;
    -v|--version) echo "dotclaude $(dc_version)"; exit 0;;
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

# Slash commands come from TWO sources: the app repo ships the generic dotclaude commands
# (the /dc* family — anyone who installs dotclaude gets them), the data repo holds personal
# ones. We materialize ~/.claude/commands as a REAL dir of per-file symlinks into both, so the
# app and personal commands coexist. Data-repo files win on a name clash (personal override).
link_commands() {  # link_commands <dst-dir> <src-dir>...
  local dst="$1"; shift
  [ -L "$dst" ] && { rm -f "$dst"; }                 # was a single dir-symlink (old layout)
  mkdir -p "$dst"
  ( shopt -s nullglob
    for f in "$dst"/*.md; do [ -L "$f" ] && rm -f "$f"; done   # drop our stale links, keep real files
    for srcdir in "$@"; do
      [ -d "$srcdir" ] || continue
      for src in "$srcdir"/*.md; do
        local name; name="$(basename "$src")"
        if [ -e "$dst/$name" ] && [ ! -L "$dst/$name" ]; then
          echo "  SKIP  $dst/$name (real file)"; continue
        fi
        ln -sf "$src" "$dst/$name"
      done
    done )
  echo "  link  $dst/  (app + data commands)"
}

# Point a project's harness memory dir at the synced repo (<data>/memory/<host>/<project>/).
# Claude auto-writes/reads ~/.claude/projects/<project>/memory/; we make that a symlink so the
# files live in the data repo (synced) instead of stranded machine-locally. Migrates any
# existing real dir in first, never clobbering a memory already in the repo.
link_memory() {  # link_memory <repo-target-dir> <claude-memory-path>
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    [ "$(readlink "$dst")" = "$src" ] && { echo "  ok    $dst"; return 0; }
    rm -f "$dst"                                   # repoint
  elif [ -d "$dst" ]; then                         # real dir from the harness — migrate, then replace
    mkdir -p "$src"
    ( shopt -s dotglob nullglob
      for f in "$dst"/*; do [ -e "$src/$(basename "$f")" ] || mv "$f" "$src/"; done )
    if [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
      echo "  WARN  $dst still has files (name clash) — left as-is, not linked"; return 0
    fi
    rmdir "$dst" 2>/dev/null || rm -rf "$dst"
  elif [ -e "$dst" ]; then
    mv "$dst" "$dst.bak.$(date +%s)"
  fi
  mkdir -p "$src"
  ln -s "$src" "$dst"; echo "  link  $dst -> $src"
}

# Register the dcmcp read-archive MCP server (the /dcrecall, /dcfind, /dcbrowse engine) at USER
# scope, so it's available in every project on this machine. TWO modes, chosen by what this box has:
#   • LOCAL  (the archive host): the archive is mounted (DOTCLAUDE_LOCAL_CHATS) → a stdio server reads it here.
#   • REMOTE (clients): no local archive but DOTCLAUDE_MCP_REMOTE points at the archive host → register
#                       `ssh <target>`; a forced command (bin/dcmcp-serve.sh) runs the server THERE
#                       and pipes MCP stdio back. Set up by bin/onboard-mcp-client.sh.
# Uses the official `claude mcp` CLI (not a hand-edit of the big ~/.claude.json) and is idempotent:
# it only (re)adds when missing or when the target changed. Best-effort — never fails the sync.
# A loud, visible skip — MCP registration silently doing nothing is exactly the onboarding
# surprise we want to avoid. Each reason says what to do about it. Returns 0 (never fails sync).
skip_mcp() { echo "  ┌─ MCP archive server NOT registered (/dcrecall, /dcfind, /dcbrowse stay inert)"; echo "  └─ reason: $1"; return 0; }

_mcp_add_local() {  # _mcp_add_local <chats> <server.py>
  local chats="$1" server="$2"
  if claude mcp get dcmcp >/dev/null 2>&1; then
    case "$(claude mcp get dcmcp 2>/dev/null)" in
      *"$server"*) echo "  ok    mcp dcmcp (local)"; return 0 ;;   # already points at our server
    esac
    claude mcp remove dcmcp -s user >/dev/null 2>&1 || claude mcp remove dcmcp >/dev/null 2>&1 || true
  fi
  if claude mcp add -s user dcmcp \
       -e DOTCLAUDE_LOCAL_CHATS="$chats" \
       -e DOTCLAUDE_MEMORY="$(dc_memory)" \
       -e DOTCLAUDE_DATA="$DATA" \
       -- uv run --script "$server" >/dev/null 2>&1; then
    echo "  add   mcp dcmcp (local, user scope)"
  else
    echo "  WARN  mcp dcmcp registration failed (run: claude mcp add … by hand)"
  fi
}

_mcp_add_remote() {  # _mcp_add_remote <ssh-target>   (forced command on the far end runs the server)
  local target="$1"
  if claude mcp get dcmcp >/dev/null 2>&1; then
    case "$(claude mcp get dcmcp 2>/dev/null)" in
      *"ssh"*"$target"*) echo "  ok    mcp dcmcp (remote → $target)"; return 0 ;;
    esac
    claude mcp remove dcmcp -s user >/dev/null 2>&1 || claude mcp remove dcmcp >/dev/null 2>&1 || true
  fi
  # No -e env: the far-end forced command (dcmcp-serve.sh) supplies the archive pointers. BatchMode
  # so a missing/uninstalled key fails fast instead of hanging the MCP transport on a prompt.
  if claude mcp add -s user dcmcp \
       -- ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$target" >/dev/null 2>&1; then
    echo "  add   mcp dcmcp (remote → ssh $target)"
  else
    echo "  WARN  mcp dcmcp remote registration failed (run: claude mcp add … by hand)"
  fi
}

register_mcp() {
  command -v claude >/dev/null 2>&1 || { skip_mcp "no 'claude' CLI on PATH — install Claude Code, then rerun bin/claude-sync.sh"; return 0; }
  dc_load_config
  local chats="${DOTCLAUDE_LOCAL_CHATS:-}" server="$APP/mcp/dcmcp_server.py" remote="${DOTCLAUDE_MCP_REMOTE:-}"
  # git backend: the claude-chats clone IS the local archive — ship-transcript.sh writes the same
  # <host>/{readable,plans,…} tree into it that a NAS archive holds. Point the local stdio server at
  # the clone so the GitHub path gets in-session recall with no NAS or SSH. (sync-session.sh pulls
  # the clone at SessionStart so it spans every machine's sessions, not just this one's.)
  if [ -z "$chats" ] && [ -z "$remote" ] && [ "${DOTCLAUDE_TRANSCRIPT_BACKEND:-}" = git ]; then
    local clone; clone="$(dc_chats)"
    [ -n "$clone" ] && [ -d "$clone/.git" ] && chats="$clone"
  fi
  if [ -n "$chats" ] && [ -d "$chats" ]; then
    # LOCAL: the archive lives here (the archive host). The stdio server runs in-process via uv.
    command -v uv >/dev/null 2>&1 || { skip_mcp "no 'uv' runtime on PATH — install uv (curl -LsSf https://astral.sh/uv/install.sh | sh), reopen shell, rerun bin/claude-sync.sh"; return 0; }
    [ -f "$server" ] || { skip_mcp "server file missing: $server"; return 0; }
    _mcp_add_local "$chats" "$server"
  elif [ -n "$remote" ]; then
    # REMOTE: no archive here → reach the archive host over SSH (uv runs THERE, not on this client).
    command -v ssh >/dev/null 2>&1 || { skip_mcp "no 'ssh' to reach the remote archive host ($remote)"; return 0; }
    _mcp_add_remote "$remote"
  else
    skip_mcp "no local archive (DOTCLAUDE_LOCAL_CHATS) and no remote (DOTCLAUDE_MCP_REMOTE) — on a client, run bin/onboard-mcp-client.sh to reach the archive host's server"
  fi
}

echo "symlinking scopes:"
link "$DATA/claude-md/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
link "$DATA/claude-md/agents"    "$CLAUDE_DIR/agents"
link "$APP/hooks"                "$CLAUDE_DIR/hooks"
# commands: app ships the generic /dc* family, data adds personal ones (data wins on clash)
link_commands "$CLAUDE_DIR/commands" "$APP/commands" "$DATA/claude-md/commands"

# plugins: share *which marketplaces are registered* (the rest of plugins/ is re-fetchable cache,
# so it stays machine-local). The file is symlinked into the data repo like the other config; if
# the harness rewrites it in place we adopt the new content into the repo before re-linking.
PLUG_SRC="$DATA/claude-md/plugins/known_marketplaces.json"
PLUG_DST="$CLAUDE_DIR/plugins/known_marketplaces.json"
if [ -e "$PLUG_DST" ] && [ ! -L "$PLUG_DST" ]; then
  mkdir -p "$(dirname "$PLUG_SRC")"; cp -f "$PLUG_DST" "$PLUG_SRC"; rm -f "$PLUG_DST"
fi
[ -d "$CLAUDE_DIR/plugins" ] && link "$PLUG_SRC" "$PLUG_DST"

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

# Per-project memory: Claude auto-reads/writes ~/.claude/projects/<project>/memory/. We point each
# at the SHARED, cross-machine memory clone (<mem>/<project>/) — its own git repo self-hosted on the
# NAS over WireGuard (dc_memory_remote), so the sensitive paths in memory sync between machines
# WITHOUT touching GitHub. Shared (not per-host) so the same project recalls memory written anywhere.
MEM="$(dc_memory)"
mkdir -p "$MEM" 2>/dev/null || true

# One-time migration: older versions kept memory in the data repo at <data>/memory/<host>/<project>/
# (per-host, on GitHub). Move that content into the shared clone before re-linking, never clobbering.
OLD="$DATA/memory/$HOST"
if [ -d "$OLD" ]; then
  echo "migrating legacy memory  ($OLD -> $MEM):"
  for od in "$OLD"/*/; do
    [ -d "$od" ] || continue
    proj="$(basename "$od")"; mkdir -p "$MEM/$proj"
    ( shopt -s dotglob nullglob
      for f in "$od"*; do [ -e "$MEM/$proj/$(basename "$f")" ] || cp -a "$f" "$MEM/$proj/"; done )
  done
fi

echo "linking per-project memory  (<mem>/<project>):"
if [ -d "$CLAUDE_DIR/projects" ]; then
  linked=0
  for projdir in "$CLAUDE_DIR/projects"/*/; do
    [ -d "$projdir" ] || continue                  # nullglob guard (literal path if no match)
    link_memory "$MEM/$(basename "$projdir")" "${projdir%/}/memory"
    linked=1
  done
  [ "$linked" = 1 ] || echo "  (no project dirs yet)"
else
  echo "  (no ~/.claude/projects yet)"
fi

echo "registering MCP archive server:"
register_mcp

echo "done. (templates/ is pull-on-demand; memory/ rides its own NAS git repo — see README)"
