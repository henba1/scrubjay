#!/usr/bin/env bash
# Interactive onboarding for a new machine. Condenses the README "Onboard a new machine"
# steps into one guided run:
#   - check deps (git, jq) and Claude Code — offer to install Claude if missing
#   - detect which coding harnesses are installed (Claude Code / opencode / codex) and record
#     which ones to sync config into (SCRUBJAY_HARNESSES)
#   - clone the sibling data repos (scrubjay-data, and scrubjay-chats only for the git backend)
#   - write ~/.config/scrubjay/{config,host}
#   - register the host + apply config into ~/.claude
#   - for the rsync-wg (P2P) backend: optionally generate a dedicated relay SSH key,
#     add the `scrubjay-receiver` ssh-alias, and print the receiver authorized_keys line
#   - set up cross-machine memory (self-hosted NAS git repo) via onboard-memory.sh
#
# Re-runnable: skips anything already in place. Prompts have sensible defaults; any value
# can be preset via its env var (SCRUBJAY_HOST, SCRUBJAY_BACKEND, …) to run unattended.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"   # sj_version / sj_is_clone (function definitions only; no side effects)

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

case "${1:-}" in
  -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0;;
  -v|--version) echo "scrubjay $(sj_version)"; exit 0;;
esac

echo; info "scrubjay onboarding  (app: $APP, version: $(sj_version))"

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
# uv runs the sjmcp archive server (mcp/sjmcp_server.py via `uv run --script`). Only the box that
# serves the archive strictly needs it, but check+offer here so claude-sync can wire MCP in one go.
if have uv; then ok "uv present ($(command -v uv))"
else
  warn "uv not found — the sjmcp MCP server (/sjrecall, /sjfind, /sjbrowse) won't register without it."
  if confirm "Install it now via the official installer?" Y; then
    curl -LsSf https://astral.sh/uv/install.sh | sh \
      && ok "uv installed (you may need to reopen your shell so 'uv' is on PATH)" \
      || warn "uv install reported an error — continuing; install it manually later."
  fi
fi

# ---- 1c) which coding harnesses this machine syncs config into ------------------------
# scrubjay is not Claude-only. Detect the agents actually installed here — each adapter's
# sjh_present (PATH-based) — and default to syncing your config into all of them, so a machine
# with opencode gets your settings/instructions/agents/commands there with no extra step. Narrow
# it at the prompt, or preset SCRUBJAY_HARNESSES=... (space-separated) to run unattended.
if [ -z "${SCRUBJAY_HARNESSES:-}" ]; then
  detected=""
  for _h in $(sj_known_harnesses); do
    sj_adapter_call "$_h" sjh_present 2>/dev/null && detected="${detected:+$detected }$_h"
  done
  [ -n "$detected" ] || detected="claude"          # nothing on PATH yet → the reference harness
  [ "$detected" = "claude" ] || info "harnesses detected on PATH: $detected"
  ask SCRUBJAY_HARNESSES "coding harnesses to sync config into (space-separated)" "$detected"
fi
export SCRUBJAY_HARNESSES
ok "harnesses: $SCRUBJAY_HARNESSES"

# ---- 2) where the repos live + who owns YOUR private data repos -----------------------
# Deliberately NOT inferred from this clone's origin. The app repo is public and you may run it
# straight from upstream; your content lives in private repos under your OWN account. Keeping the
# two apart is what makes forking unnecessary (and stops a fresh clone from reaching for the
# maintainer's private repos). sj-bootstrap.sh creates + seeds them.
sj_is_clone || warn "this app dir has no .git — self-update won't work; install via 'git clone', not a source tarball."
DEFAULT_OWNER="${SCRUBJAY_OWNER:-$(command -v gh >/dev/null 2>&1 && gh api user --jq .login 2>/dev/null)}"
ask SCRUBJAY_OWNER "GitHub account for your PRIVATE data repos" "${DEFAULT_OWNER:-}"
[ -n "$SCRUBJAY_OWNER" ] || die "no GitHub account given — set SCRUBJAY_OWNER=<your-gh-user>"
export SCRUBJAY_OWNER
ok "private repos owner: $SCRUBJAY_OWNER"

DEFAULT_BASE="$(dirname "$APP")"                # siblings of the app clone
ask BASE "clone base dir for the data repos" "$DEFAULT_BASE"
ask SCRUBJAY_HOST "stable host name" "$(hostname -s 2>/dev/null || echo host)"
HOST="$SCRUBJAY_HOST"
DATA_DIR="$BASE/scrubjay-data"
CHATS_DIR="$BASE/scrubjay-chats"

# ---- 3) backend choice ----------------------------------------------------------------
if [ -z "${SCRUBJAY_BACKEND:-}" ]; then
  echo; info "Session-relay backend — where each session's records go (pick one):"
  echo "    1) rsync-wg  peer-to-peer to your own NAS over WireGuard — records stay off third parties; needs a NAS"
  echo "    2) local     this box HAS the NAS mounted — copy straight in, no network hop"
  echo "    3) git       push to a private scrubjay-chats repo on GitHub — no NAS or WireGuard to run"
  echo "    4) off       don't ship sessions"
  ask BACKEND_CHOICE "choose 1-4" ""
  case "$BACKEND_CHOICE" in
    1) SCRUBJAY_BACKEND=rsync-wg;; 2) SCRUBJAY_BACKEND=local;;
    3) SCRUBJAY_BACKEND=git;;      4) SCRUBJAY_BACKEND=off;;
    "") die "no backend chosen — pick 1-4, or preset SCRUBJAY_BACKEND (rsync-wg|local|git|off)";;
    *)  die "invalid choice '$BACKEND_CHOICE'";;
  esac
fi
BACKEND="$SCRUBJAY_BACKEND"
ok "backend: $BACKEND"

# backend-specific settings
WG_TARGET=""; WG_KEY=""; LOCAL_CHATS=""; RECV_HOST=""; RECV_USER=""; RECV_PORT=""; RECV_PATH=""; GEN_KEY=0
case "$BACKEND" in
  rsync-wg)
    ask RECV_USER "receiver SSH user" "scrubjay-rx"
    ask RECV_HOST "receiver host/IP (reachable over WG/LAN)" "192.168.1.10"
    ask RECV_PORT "receiver SSH port" "22"
    ask RECV_PATH "receiver rrsync root (its authorized_keys -wo dir)" "/srv/scrubjay-chats"
    ask WG_KEY "relay SSH key path" "$HOME/.ssh/scrubjay_transcripts_ed25519"
    # ssh destination ONLY — no remote path. rrsync pins the root; paths are relative to it.
    WG_TARGET="$RECV_USER@scrubjay-receiver"              # alias resolved via ~/.ssh/config
    [ -f "$WG_KEY" ] || confirm "generate the dedicated relay SSH key now?" Y && GEN_KEY=1
    ;;
  local)
    # If the NAS share details are given (or the user opts in), provision + verify the mount via
    # sj-mount.sh (which creates <mountpoint>/scrubjay-storage and prints it); otherwise assume the
    # box already has the NAS mounted and just take the storage path. For an unattended run, preset
    # SCRUBJAY_NAS_SERVER (+ SCRUBJAY_ASSUME_YES=1 so it installs the mount without prompting).
    if [ -n "${SCRUBJAY_NAS_SERVER:-}" ] || confirm "set up the NAS mount now (this box isn't mounted yet)?" N; then
      ask SCRUBJAY_NAS_PROTO      "NAS protocol (nfs|cifs)"       "nfs"
      ask SCRUBJAY_NAS_SERVER     "NAS host/IP"                   ""
      ask SCRUBJAY_NAS_EXPORT     "export/share path on the NAS"  "/export/scrubjay"
      ask SCRUBJAY_NAS_MOUNTPOINT "local mountpoint"              "/mnt/nas1"
      export SCRUBJAY_NAS_PROTO SCRUBJAY_NAS_SERVER SCRUBJAY_NAS_EXPORT SCRUBJAY_NAS_MOUNTPOINT
      LOCAL_CHATS="$("$APP/bin/sj-mount.sh")" \
        || die "NAS mount setup failed — mount it by hand, then re-run bin/onboard.sh."
    else
      ask LOCAL_CHATS "NAS storage root (this box's mount)" "/mnt/nas1/scrubjay-storage"
    fi
    ;;
esac

# ---- 4) create, seed + clone the private sibling repos --------------------------------
# sj-bootstrap.sh creates them under $SCRUBJAY_OWNER if they don't exist yet (via `gh`), clones
# them, and seeds a fresh scrubjay-data from skeleton/data — claude-sync.sh hard-requires
# settings/settings.base.json, and that file is where the SessionStart/SessionEnd hooks live.
mkdir -p "$BASE"
SCRUBJAY_BACKEND="$BACKEND" BASE="$BASE" "$APP/bin/sj-bootstrap.sh" \
  || die "bootstrap failed — create the private repo(s) it named, then re-run bin/onboard.sh"

# ---- 5) write the machine-local pointer ----------------------------------------------
CFGDIR="$HOME/.config/scrubjay"; CFG="$CFGDIR/config"; mkdir -p "$CFGDIR"
if [ -f "$CFG" ] && ! confirm "overwrite existing $CFG?" N; then
  warn "keeping existing $CFG (review it matches the choices above)"
else
  [ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$(date +%s)"
  {
    echo ": \"\${SCRUBJAY_DATA:=$DATA_DIR}\""
    echo ": \"\${SCRUBJAY_CHATS:=$CHATS_DIR}\""
    echo ": \"\${SCRUBJAY_HARNESSES:=$SCRUBJAY_HARNESSES}\""
    echo ": \"\${SCRUBJAY_TRANSCRIPT_BACKEND:=$BACKEND}\""
    [ "$BACKEND" = local ]    && echo ": \"\${SCRUBJAY_LOCAL_CHATS:=$LOCAL_CHATS}\""
    [ "$BACKEND" = rsync-wg ] && { echo ": \"\${SCRUBJAY_WG_TARGET:=$WG_TARGET}\""
                                   echo ": \"\${SCRUBJAY_WG_SSHKEY:=$WG_KEY}\""; }
  } > "$CFG"
  ok "wrote $CFG"
fi

# ---- 6) generate relay key + ssh alias (rsync-wg) ------------------------------------
if [ "$GEN_KEY" = 1 ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ -f "$WG_KEY" ]; then ok "relay key already exists ($WG_KEY)"
  else ssh-keygen -t ed25519 -N "" -f "$WG_KEY" -C "$HOST transcripts" && ok "generated $WG_KEY"; fi
  SSHCFG="$HOME/.ssh/config"; touch "$SSHCFG"; chmod 600 "$SSHCFG"
  if grep -qE '^[Hh]ost[[:space:]]+scrubjay-receiver$' "$SSHCFG"; then
    ok "ssh alias 'scrubjay-receiver' already present"
  else
    { echo; echo "Host scrubjay-receiver"; echo "    HostName $RECV_HOST"
      echo "    Port $RECV_PORT"; echo "    User $RECV_USER"
      echo "    IdentityFile $WG_KEY"; } >> "$SSHCFG"
    ok "added ssh alias 'scrubjay-receiver' → $RECV_USER@$RECV_HOST:$RECV_PORT"
  fi
fi

# ---- 7) register host + apply config into every selected harness ----------------------
# sync-config.sh walks $SCRUBJAY_HARNESSES and runs each adapter's apply (claude-sync.sh for
# Claude, the opencode.json/agents/commands merge for opencode). The Claude host dir is a
# hard requirement of claude-sync.sh, so register it only when Claude is actually selected.
export CLAUDE_HOST="$HOST"
info "registering host '$HOST' and applying config into: $SCRUBJAY_HARNESSES …"
case " $SCRUBJAY_HARNESSES " in
  *" claude "*) "$APP/bin/claude-register-host.sh" --host "$HOST" || die "host registration failed" ;;
esac
"$APP/bin/sync-config.sh" --host "$HOST" || die "sync-config failed"

# ---- 7b) cross-machine memory ---------------------------------------------------------
# Its own git repo, hosted the same way you host transcripts: self-hosted on the NAS for the
# local/rsync-wg backends (never leaves your hardware); a private GitHub repo for the git backend
# (simpler wiring, but stores your memory's real filesystem paths off your hardware). onboard-memory.sh
# surfaces that trade-off and derives the GitHub repo from your owner for the git backend.
if [ "$BACKEND" = git ]; then mem_where="a private GitHub repo (holds real filesystem paths — see the privacy note)"
else mem_where="its own self-hosted NAS git repo"; fi
if confirm "set up cross-machine memory ($mem_where)?" Y; then
  MEM_RECV_HOST="${RECV_HOST:-}" MEM_RECV_PORT="${RECV_PORT:-22}" \
    "$APP/bin/onboard-memory.sh" || warn "memory onboarding had issues — see docs/memory-sync.md"
fi

# ---- 7c) MCP remote: a client with no local archive queries the archive host over SSH -
# (On a 'local' backend the box HAS the archive — claude-sync already registered MCP locally.)
if [ "$BACKEND" != local ]; then
  if confirm "set up archive querying over MCP (/sjrecall, /sjfind, /sjbrowse against the archive host)?" Y; then
    ask MCP_USER "owner account ON THE ARCHIVE HOST (the one with uv + the scrubjay clone)" "${MCP_USER:-$USER}"
    MCP_USER="$MCP_USER" MCP_RECV_HOST="${RECV_HOST:-}" MCP_RECV_PORT="${RECV_PORT:-22}" \
      "$APP/bin/onboard-mcp-client.sh" || warn "MCP-client onboarding had issues — see the README 'Query the archive (MCP)' section"
  fi
fi

# ---- 8) offer to push the new host dir ------------------------------------------------
if confirm "commit + push the new hosts/$HOST entry to scrubjay-data?" Y; then
  ( cd "$DATA_DIR" && git add -A && git commit -q -m "host $HOST" \
      && { git pull --rebase -q 2>/dev/null; git push -q; } ) \
    && ok "pushed hosts/$HOST" || warn "push skipped/failed — do it manually in $DATA_DIR"
fi

# ---- 9) what's left -------------------------------------------------------------------
echo; ok "onboarding complete for '$HOST' (backend: $BACKEND)"
if [ "$BACKEND" = rsync-wg ] && [ -f "$WG_KEY.pub" ]; then
  echo
  info "Final step — authorize this machine on the receiver. Add this ONE line to the"
  info "receiver's ~scrubjay-rx/.ssh/authorized_keys (replace <APP> with the receiver's"
  info "scrubjay checkout path — the wrapper widens the archive to group-read after each push):"
  echo
  echo "    command=\"<APP>/bin/sj-receive.sh $RECV_PATH\",restrict $(cat "$WG_KEY.pub")"
  echo
  info "Then verify from here:  ssh scrubjay-receiver true   (should succeed silently),"
  info "and a session-end will rsync transcripts/subagents/plans to the NAS."
fi
