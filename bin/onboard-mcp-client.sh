#!/usr/bin/env bash
# Set up THIS machine (a client with NO local archive — snellius, a laptop) to query the dotclaude
# archive over SSH: the Phase-2 remote path. Idempotent — safe to re-run to enable or repair. It:
#   - derives the connection to the archive host from the working `claude-receiver` relay alias
#     (host, port, ProxyJump) — so MCP rides the exact same hops as the transcript relay;
#   - generates a dedicated MCP ssh key + a `claude-mcp` alias to the archive-OWNER account on the
#     receiver (the account that has uv + the dotclaude clone + archive read; the locked relay
#     account usually has none of those, so MCP can't reuse it);
#   - sets DOTCLAUDE_MCP_REMOTE in ~/.config/dotclaude/config and registers the MCP server via
#     claude-sync (a remote `ssh` entry; the far end runs bin/dcmcp-serve.sh as a forced command);
#   - prints the authorized_keys line(s) to install on the receiver (and the edge, if a ProxyJump is
#     in play) — the server side stays manual, exactly like the relay + memory keys.
# Unattended via env: MCP_USER (required), MCP_KEY, MCP_ALIAS, MCP_RELAY_ALIAS (default
# claude-receiver), MCP_RECV_HOST, MCP_RECV_PORT, MCP_RECV_JUMP, MCP_SERVE_PATH.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; dc_load_config

info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }

CFGDIR="$HOME/.config/dotclaude"; CFG="$CFGDIR/config"; mkdir -p "$CFGDIR"; touch "$CFG"

# If the archive is mounted here, MCP runs locally (Phase 1) — nothing remote to set up.
chats="${DOTCLAUDE_LOCAL_CHATS:-}"
if [ -n "$chats" ] && [ -d "$chats" ]; then
  ok "this box has the archive mounted ($chats) — MCP runs locally; no remote path needed."
  exit 0
fi

ALIAS="${MCP_ALIAS:-claude-mcp}"
RELAY_ALIAS="${MCP_RELAY_ALIAS:-claude-receiver}"
key="${MCP_KEY:-$HOME/.ssh/claude_mcp_ed25519}"
serve="${MCP_SERVE_PATH:-<receiver-dotclaude-clone>/bin/dcmcp-serve.sh}"

# Derive every connection field from the working relay alias — host, port, ProxyJump — so MCP rides
# the same hops as the relay. Only User + key differ (the receiver pins each key to ONE forced
# command: rrsync to append transcripts, dcmcp-serve to read the archive).
recv_host="$(ssh -G "$RELAY_ALIAS" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
recv_port="$(ssh -G "$RELAY_ALIAS" 2>/dev/null | awk '/^port /{print $2; exit}')"
recv_jump="$(ssh -G "$RELAY_ALIAS" 2>/dev/null | awk '/^proxyjump /{print $2; exit}')"

host="${MCP_RECV_HOST:-$recv_host}"
port="${MCP_RECV_PORT:-${recv_port:-22}}"
jump="${MCP_RECV_JUMP:-$recv_jump}"
muser="${MCP_USER:-}"

[ -n "$host" ]  || { warn "no '$RELAY_ALIAS' alias and no MCP_RECV_HOST — onboard the transcript relay first, or set MCP_RECV_HOST and re-run."; exit 1; }
[ -n "$muser" ] || { warn "set MCP_USER=<owner account on the archive host> — the account with uv + the dotclaude clone + archive read (usually NOT the relay account), then re-run."; exit 1; }

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
[ -f "$key" ] || { ssh-keygen -t ed25519 -N "" -f "$key" -C "$(dc_host) dcmcp" >/dev/null && ok "generated MCP key: $key"; }

SSHCFG="$HOME/.ssh/config"; touch "$SSHCFG"; chmod 600 "$SSHCFG"
if ! grep -qE "^[Hh]ost[[:space:]]+$ALIAS\$" "$SSHCFG"; then
  { echo; echo "Host $ALIAS"; echo "    HostName $host"; echo "    Port $port"
    echo "    User $muser"; echo "    IdentityFile $key"; echo "    IdentitiesOnly yes"
    echo "    RequestTTY no"
    [ -n "$jump" ] && [ "$jump" != none ] && echo "    ProxyJump $jump"; } >> "$SSHCFG"
  ok "ssh alias '$ALIAS' → $muser@$host:$port${jump:+ via $jump}"
else
  ok "ssh alias '$ALIAS' already present in $SSHCFG"
fi

# persist the pointer (idempotent; append only if absent, back up first)
if ! grep -q DOTCLAUDE_MCP_REMOTE "$CFG"; then
  cp "$CFG" "$CFG.bak.$(date +%s)"
  { echo "# dcmcp Phase-2: query the archive host's MCP server over SSH (far-end forced cmd:"
    echo "# bin/dcmcp-serve.sh). The alias carries host/port/ProxyJump; see bin/onboard-mcp-client.sh."
    echo ": \"\${DOTCLAUDE_MCP_REMOTE:=$ALIAS}\""; } >> "$CFG"
  ok "wrote DOTCLAUDE_MCP_REMOTE=$ALIAS to $CFG"
else
  ok "DOTCLAUDE_MCP_REMOTE already set in $CFG"
fi
export DOTCLAUDE_MCP_REMOTE="$ALIAS"

# register the remote MCP entry (idempotent; the server activates on the next Claude session)
"$APP/bin/claude-sync.sh" >/dev/null 2>&1 && ok "claude-sync applied (MCP remote registered)" || warn "claude-sync failed"

# The receiver side stays manual (like the relay + memory keys). Print the exact line(s) to install.
pub="$(cat "$key.pub")"
echo
info "Final step — authorize this machine on the archive host. Add ONE line to the '$muser' user's"
info "~/.ssh/authorized_keys ON THE ARCHIVE HOST (pins this key to the read-only server, nothing else):"
echo
printf '    command="%s",restrict %s\n' "$serve" "$pub"
echo
info "Use the ABSOLUTE path of bin/dcmcp-serve.sh in the dotclaude clone on the archive host"
[ "${serve#<}" = "$serve" ] || info "(the <…> placeholder above means it couldn't be inferred from here — fill it in)."
if [ -n "$jump" ] && [ "$jump" != none ]; then
  echo
  info "ProxyJump detected ($jump) — the MCP key also needs the EDGE/bastion to allow the tunnel to"
  info "the receiver. Add to the jump user's ~/.ssh/authorized_keys on '$jump' (same target the relay"
  info "key already tunnels to):"
  echo
  printf '    restrict,port-forwarding,permitopen="%s:%s",command="/bin/false" %s\n' "$host" "$port" "$pub"
fi
echo
info "Then verify from here (auth + forced command + server launch; EOF makes the server exit 0):"
info "    ssh $ALIAS </dev/null && echo 'dcmcp server launched OK'"
info "First connection is slow once — uv resolves the server's deps on the archive host, then caches."
ok "dcmcp remote configured on '$(dc_host)' → $ALIAS  (activates on the next Claude session)"
