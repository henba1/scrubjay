#!/usr/bin/env bash
# Receiver-side entry point for the archive READ path. A remote client with no local archive (a
# laptop or HPC login node) reaches the archive host by SSHing in and having THIS run as a forced
# command, so everything executes here (where the archive + uv + config are). Pin it in the owner
# account's authorized_keys:
#
#   command="<APP>/bin/sjmcp-serve.sh",restrict <client-mcp-pubkey>
#
# `restrict` (no pty/forwarding/agent/X11) + the forced command bound a leaked key to exactly the
# verbs below — and every one of them confines its reads to the archive root. The key can only ever
# *read* the archive, mirroring how the relay key can only ever *append* to it (bin/sj-receive.sh).
#
# It speaks three things, chosen by $SSH_ORIGINAL_COMMAND:
#
#   (empty)            the MCP stdio server (mcp/sjmcp_server.py) — recall/search/get, the Phase-2
#                      read path, and what `claude mcp add … -- ssh <alias>` invokes.
#   resolve <sid>      TSV `<relpath> <lines> <mtime>` for every archived copy of a session.
#   fetch <relpath>    a tar stream of that archive entry (file or directory).
#
# `resolve`/`fetch` exist so a host on the write-only rsync-wg relay can pull a session back down
# for `claude --resume` (see hooks/transports/rsync-wg.sh, bin/sj-resume.sh). They are NOT a wider
# grant than the MCP server already gives this key: sj_get(format="raw") hands out the same raw
# .jsonl bytes. They are a cheaper, binary-safe channel for data the key may already read — a whole
# transcript over MCP would have to cross the client's context window to reach its disk.
# Anything else is refused.
set -euo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

# A forced command runs with sshd's minimal PATH; uv usually lives in the owner's ~/.local/bin.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

chats="${SCRUBJAY_LOCAL_CHATS:-}"
[ -n "$chats" ] && [ -d "$chats" ] || { echo "sjmcp-serve: no local archive (SCRUBJAY_LOCAL_CHATS) on $(hostname) — nothing to serve" >&2; exit 1; }

# Resolve <relpath> against the archive root, refusing anything that could point outside it. Belt
# and braces: reject the obvious lexical attacks (absolute path, any '..' component, a leading '-'
# that tar could read as a flag) AND re-check the realpath, which is what actually stops a symlink
# inside the archive from being used as a way out.
confine() {  # confine <relpath> -> absolute path under $chats, or exit 1
  local rel="$1" root abs
  case "$rel" in
    "" | /* | -*) echo "sjmcp-serve: refusing path '$rel'" >&2; exit 1 ;;
    *..*)         echo "sjmcp-serve: refusing path '$rel'" >&2; exit 1 ;;
  esac
  root="$(sj_realpath "$chats")" || { echo "sjmcp-serve: bad archive root" >&2; exit 1; }
  abs="$(sj_realpath "$chats/$rel")" || { echo "sjmcp-serve: no such entry '$rel'" >&2; exit 1; }
  case "$abs" in
    "$root"/*) printf '%s' "$abs" ;;
    *)         echo "sjmcp-serve: '$rel' escapes the archive root" >&2; exit 1 ;;
  esac
}

serve_resolve() {  # serve_resolve <sid|sid8>
  local sid="$1"
  # A session id is hex + dashes. Anything else is someone probing, not a client.
  case "$sid" in
    "" | *[!0-9a-fA-F-]*) echo "sjmcp-serve: not a session id: '$sid'" >&2; exit 1 ;;
  esac
  [ "${#sid}" -le 36 ] || { echo "sjmcp-serve: session id too long" >&2; exit 1; }
  sj_archive_resolve "$chats" "$sid"
}

serve_fetch() {  # serve_fetch <relpath>
  local abs rel; abs="$(confine "$1")"; rel="${abs#"$(sj_realpath "$chats")"/}"
  tar -C "$(sj_realpath "$chats")" -cf - -- "$rel"
}

cmd="${SSH_ORIGINAL_COMMAND:-}"
case "$cmd" in
  "")          ;;                                        # fall through to the MCP server below
  "resolve "*) serve_resolve "${cmd#resolve }"; exit 0 ;;
  "fetch "*)   serve_fetch   "${cmd#fetch }";   exit 0 ;;
  *)           echo "sjmcp-serve: denied (allowed: resolve <sid>, fetch <relpath>, or no command for MCP)" >&2; exit 1 ;;
esac

command -v uv >/dev/null 2>&1 || { echo "sjmcp-serve: 'uv' not found for $(whoami) — install it for the account this forced command runs as" >&2; exit 1; }
[ -f "$APP/mcp/sjmcp_server.py" ] || { echo "sjmcp-serve: server missing at $APP/mcp/sjmcp_server.py" >&2; exit 1; }

# Hand the same pointers the local server gets to the child, then become the (read-only) server.
# Assign before export so a failing sj_data() surfaces instead of being masked by export's status.
mem="$(sj_memory)"
data="$(sj_data)" || { echo "sjmcp-serve: SCRUBJAY_DATA not set" >&2; exit 1; }
export SCRUBJAY_LOCAL_CHATS="$chats" SCRUBJAY_MEMORY="$mem" SCRUBJAY_DATA="$data"
exec uv run --script "$APP/mcp/sjmcp_server.py"
