#!/usr/bin/env bash
# Receiver-side launcher for the dcmcp archive server — the Phase-2 read path. A remote client
# with no local archive (a laptop or HPC login node) reaches the archive host's full archive by SSHing in and having
# THIS run as a forced command, so the server executes here (where the archive + uv + config are)
# and speaks MCP stdio back over the SSH pipe. Pin it in the owner account's authorized_keys:
#
#   command="<APP>/bin/dcmcp-serve.sh",restrict <client-mcp-pubkey>
#
# `restrict` (no pty/forwarding/agent/X11) + the forced command bound a leaked key to exactly this
# ONE read-only server — and the server itself confines every read to the archive roots. The key
# can only ever *read* the archive, mirroring how the relay key can only ever *append* to it.
# Whatever the client puts in $SSH_ORIGINAL_COMMAND is ignored.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; dc_load_config

# A forced command runs with sshd's minimal PATH; uv usually lives in the owner's ~/.local/bin.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

chats="${DOTCLAUDE_LOCAL_CHATS:-}"
[ -n "$chats" ] && [ -d "$chats" ] || { echo "dcmcp-serve: no local archive (DOTCLAUDE_LOCAL_CHATS) on $(hostname) — nothing to serve" >&2; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "dcmcp-serve: 'uv' not found for $(whoami) — install it for the account this forced command runs as" >&2; exit 1; }
[ -f "$APP/mcp/dcmcp_server.py" ] || { echo "dcmcp-serve: server missing at $APP/mcp/dcmcp_server.py" >&2; exit 1; }

# Hand the same pointers the local server gets to the child, then become the (read-only) server.
export DOTCLAUDE_LOCAL_CHATS="$chats" DOTCLAUDE_MEMORY="$(dc_memory)" DOTCLAUDE_DATA="$(dc_data)"
exec uv run --script "$APP/mcp/dcmcp_server.py"
