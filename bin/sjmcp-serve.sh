#!/usr/bin/env bash
# Receiver-side launcher for the sjmcp archive server — the Phase-2 read path. A remote client
# with no local archive (a laptop or HPC login node) reaches the archive host's full archive by SSHing in and having
# THIS run as a forced command, so the server executes here (where the archive + uv + config are)
# and speaks MCP stdio back over the SSH pipe. Pin it in the owner account's authorized_keys:
#
#   command="<APP>/bin/sjmcp-serve.sh",restrict <client-mcp-pubkey>
#
# `restrict` (no pty/forwarding/agent/X11) + the forced command bound a leaked key to exactly this
# ONE read-only server — and the server itself confines every read to the archive roots. The key
# can only ever *read* the archive, mirroring how the relay key can only ever *append* to it.
# Whatever the client puts in $SSH_ORIGINAL_COMMAND is ignored.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

# A forced command runs with sshd's minimal PATH; uv usually lives in the owner's ~/.local/bin.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

chats="${SCRUBJAY_LOCAL_CHATS:-}"
[ -n "$chats" ] && [ -d "$chats" ] || { echo "sjmcp-serve: no local archive (SCRUBJAY_LOCAL_CHATS) on $(hostname) — nothing to serve" >&2; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "sjmcp-serve: 'uv' not found for $(whoami) — install it for the account this forced command runs as" >&2; exit 1; }
[ -f "$APP/mcp/sjmcp_server.py" ] || { echo "sjmcp-serve: server missing at $APP/mcp/sjmcp_server.py" >&2; exit 1; }

# Hand the same pointers the local server gets to the child, then become the (read-only) server.
# Assign before export so a failing sj_data() surfaces instead of being masked by export's status.
mem="$(sj_memory)"
data="$(sj_data)" || { echo "sjmcp-serve: SCRUBJAY_DATA not set" >&2; exit 1; }
export SCRUBJAY_LOCAL_CHATS="$chats" SCRUBJAY_MEMORY="$mem" SCRUBJAY_DATA="$data"
exec uv run --script "$APP/mcp/sjmcp_server.py"
