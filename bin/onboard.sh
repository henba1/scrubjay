#!/usr/bin/env bash
# Interactive onboarding for a new machine. Condenses the README "Onboard a new machine"
# steps into one guided run:
#   - check deps (git, jq) and Claude Code — offer to install Claude if missing
#   - clone the sibling data repos (dotclaude-data, and claude-chats only for the git backend)
#   - write ~/.config/dotclaude/{config,host}
#   - register the host + apply config into ~/.claude
#   - for the rsync-wg (P2P) backend: optionally generate a dedicated relay SSH key,
#     add the `claude-receiver` ssh-alias, and print the receiver authorized_keys line
#   - set up cross-machine memory (self-hosted NAS git repo) via onboard-memory.sh
#
# Re-runnable: skips anything already in place. Prompts have sensible defaults; any value
# can be preset via its env var (DOTCLAUDE_HOST, DOTCLAUDE_BACKEND, …) to run unattended.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- pretty output + prompt helpers ---------------------------------------------------
info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ask() {  # ask VARNAME "prompt" "default"   (keeps an existing env value; falls back to default)
  local __var="$1" __prompt="$2" __def="${3:-}" __cur="" __ans=""
  eval "__cur=\${$__var:-}"
  if [ -n "$__cur" ]; then printf -v "$__var" '%s' "$__cur"; return 0; fi
  if [ -t 0 ]; then read -r -p "  $__prompt [${__def}]: " __ans || __ans=""; fi
  [ -n "$__ans" ] || __ans="$__def"
  printf -v "$__var" '%s' "$__ans"
}
confirm() {  # confirm "prompt" "Y"|"N"
  local __p="$1" __d="${2:-Y}" __a=""
  if [ ! -t 0 ]; then [ "$__d" = "Y" ]; return; fi
  read -r -p "  $__p $([ "$__d" = Y ] && echo '[Y/n]' || echo '[y/N]') " __a || __a=""
  __a="${__a:-$__d}"; case "$__a" in [Yy]*) return 0;; *) return 1;; esac
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0
fi

echo; info "dotclaude onboarding  (app: $APP)"

# ---- 1) dependencies ------------------------------------------------------------------
have git || die "git not found — install it first (e.g. sudo apt install git)."
have jq  || die "jq not found — install it first (e.g. sudo apt install jq)."
if have claude; then ok "Claude Code present ($(command -v claude))"
else
  warn "Claude Code ('claude') not found."
  if confirm "Install it now via the official installer?" Y; then
    curl -fsSL https://claude.ai/install.sh | bash \
      && ok "Claude installed (you may need to reopen your shell so 'claude' is on PATH)" \
      || warn "Claude install reported an error — continuing; install it manually later."
  fi
fi

# ---- 2) where the repos live + remote owner (inferred from this clone's origin) -------
ORIGIN="$(git -C "$APP" remote get-url origin 2>/dev/null || echo)"
case "$ORIGIN" in https://github.com/*) ORIGIN="git@github.com:${ORIGIN#https://github.com/}";; esac
[ -n "$ORIGIN" ] || die "could not read this repo's origin remote."
REMOTE_BASE="${ORIGIN%/dotclaude.git}"          # e.g. git@github.com:owner
ok "remote owner: $REMOTE_BASE"

DEFAULT_BASE="$(dirname "$APP")"                # siblings of the app clone
ask BASE "clone base dir for the data repos" "$DEFAULT_BASE"
ask DOTCLAUDE_HOST "stable host name" "$(hostname -s 2>/dev/null || echo host)"
HOST="$DOTCLAUDE_HOST"
DATA_DIR="$BASE/dotclaude-data"
CHATS_DIR="$BASE/claude-chats"

# ---- 3) backend choice ----------------------------------------------------------------
if [ -z "${DOTCLAUDE_BACKEND:-}" ]; then
  echo; info "Session-relay backend:"
  echo "    1) rsync-wg  peer-to-peer over WireGuard to the NAS receiver  (recommended for clients)"
  echo "    2) local     this box HAS the NAS mounted (copy straight in)"
  echo "    3) git       GitHub stopgap via the claude-chats repo"
  echo "    4) off       don't ship sessions"
  ask BACKEND_CHOICE "choose 1-4" "1"
  case "$BACKEND_CHOICE" in
    1) DOTCLAUDE_BACKEND=rsync-wg;; 2) DOTCLAUDE_BACKEND=local;;
    3) DOTCLAUDE_BACKEND=git;;      4) DOTCLAUDE_BACKEND=off;;
    *) die "invalid choice '$BACKEND_CHOICE'";;
  esac
fi
BACKEND="$DOTCLAUDE_BACKEND"
ok "backend: $BACKEND"

# backend-specific settings
WG_TARGET=""; WG_KEY=""; LOCAL_CHATS=""; RECV_HOST=""; RECV_USER=""; RECV_PORT=""; RECV_PATH=""; GEN_KEY=0
case "$BACKEND" in
  rsync-wg)
    ask RECV_USER "receiver SSH user" "claude-rx"
    ask RECV_HOST "receiver host/IP (reachable over WG/LAN)" "192.168.1.10"
    ask RECV_PORT "receiver SSH port" "22"
    ask RECV_PATH "receiver rrsync root (its authorized_keys -wo dir)" "/srv/claude-chats"
    ask WG_KEY "relay SSH key path" "$HOME/.ssh/claude_transcripts_ed25519"
    # ssh destination ONLY — no remote path. rrsync pins the root; paths are relative to it.
    WG_TARGET="$RECV_USER@claude-receiver"              # alias resolved via ~/.ssh/config
    [ -f "$WG_KEY" ] || confirm "generate the dedicated relay SSH key now?" Y && GEN_KEY=1
    ;;
  local)
    ask LOCAL_CHATS "NAS chats root (this box's mount)" "/mnt/nas1/Claude-Code-chats"
    ;;
esac

# ---- 4) clone sibling repos -----------------------------------------------------------
clone_if_absent() {  # clone_if_absent <url> <dir> <label>
  local url="$1" dir="$2" label="$3"
  if [ -d "$dir/.git" ]; then ok "$label already cloned ($dir)"
  else info "cloning $label → $dir"; git clone "$url" "$dir" || die "clone failed: $url"; fi
}
mkdir -p "$BASE"
clone_if_absent "$REMOTE_BASE/dotclaude-data.git" "$DATA_DIR" "dotclaude-data"
[ "$BACKEND" = git ] && clone_if_absent "$REMOTE_BASE/claude-chats.git" "$CHATS_DIR" "claude-chats"

# ---- 5) write the machine-local pointer ----------------------------------------------
CFGDIR="$HOME/.config/dotclaude"; CFG="$CFGDIR/config"; mkdir -p "$CFGDIR"
if [ -f "$CFG" ] && ! confirm "overwrite existing $CFG?" N; then
  warn "keeping existing $CFG (review it matches the choices above)"
else
  [ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$(date +%s)"
  {
    echo ": \"\${DOTCLAUDE_DATA:=$DATA_DIR}\""
    echo ": \"\${DOTCLAUDE_CHATS:=$CHATS_DIR}\""
    echo ": \"\${DOTCLAUDE_TRANSCRIPT_BACKEND:=$BACKEND}\""
    [ "$BACKEND" = local ]    && echo ": \"\${DOTCLAUDE_LOCAL_CHATS:=$LOCAL_CHATS}\""
    [ "$BACKEND" = rsync-wg ] && { echo ": \"\${DOTCLAUDE_WG_TARGET:=$WG_TARGET}\""
                                   echo ": \"\${DOTCLAUDE_WG_SSHKEY:=$WG_KEY}\""; }
  } > "$CFG"
  ok "wrote $CFG"
fi

# ---- 6) generate relay key + ssh alias (rsync-wg) ------------------------------------
if [ "$GEN_KEY" = 1 ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ -f "$WG_KEY" ]; then ok "relay key already exists ($WG_KEY)"
  else ssh-keygen -t ed25519 -N "" -f "$WG_KEY" -C "$HOST transcripts" && ok "generated $WG_KEY"; fi
  SSHCFG="$HOME/.ssh/config"; touch "$SSHCFG"; chmod 600 "$SSHCFG"
  if grep -qE '^[Hh]ost[[:space:]]+claude-receiver$' "$SSHCFG"; then
    ok "ssh alias 'claude-receiver' already present"
  else
    { echo; echo "Host claude-receiver"; echo "    HostName $RECV_HOST"
      echo "    Port $RECV_PORT"; echo "    User $RECV_USER"
      echo "    IdentityFile $WG_KEY"; } >> "$SSHCFG"
    ok "added ssh alias 'claude-receiver' → $RECV_USER@$RECV_HOST:$RECV_PORT"
  fi
fi

# ---- 7) register host + apply config --------------------------------------------------
export CLAUDE_HOST="$HOST"
info "registering host '$HOST' and applying config…"
"$APP/bin/claude-register-host.sh" --host "$HOST" || die "host registration failed"
"$APP/bin/claude-sync.sh"          --host "$HOST" || die "claude-sync failed"

# ---- 7b) cross-machine memory (self-hosted NAS git repo) ------------------------------
if confirm "set up cross-machine memory (its own self-hosted NAS git repo)?" Y; then
  MEM_RECV_HOST="${RECV_HOST:-}" MEM_RECV_PORT="${RECV_PORT:-22}" \
    "$APP/bin/onboard-memory.sh" || warn "memory onboarding had issues — see docs/memory-sync.md"
fi

# ---- 8) offer to push the new host dir ------------------------------------------------
if confirm "commit + push the new hosts/$HOST entry to dotclaude-data?" Y; then
  ( cd "$DATA_DIR" && git add -A && git commit -q -m "host $HOST" \
      && { git pull --rebase -q 2>/dev/null; git push -q; } ) \
    && ok "pushed hosts/$HOST" || warn "push skipped/failed — do it manually in $DATA_DIR"
fi

# ---- 9) what's left -------------------------------------------------------------------
echo; ok "onboarding complete for '$HOST' (backend: $BACKEND)"
if [ "$BACKEND" = rsync-wg ] && [ -f "$WG_KEY.pub" ]; then
  echo
  info "Final step — authorize this machine on the receiver. Add this ONE line to the"
  info "receiver's ~claude-rx/.ssh/authorized_keys:"
  echo
  echo "    command=\"rrsync -wo $RECV_PATH\",restrict $(cat "$WG_KEY.pub")"
  echo
  info "Then verify from here:  ssh claude-receiver true   (should succeed silently),"
  info "and a session-end will rsync transcripts/subagents/plans to the NAS."
fi
