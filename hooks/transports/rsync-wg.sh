#!/usr/bin/env bash
# Transcript backend: peer-to-peer rsync over a WireGuard/SSH tunnel to the NAS receiver —
# no third-party server in the path. The receiver pins the destination via a forced
# command="rrsync -wo <root>" in authorized_keys, so paths sent here are RELATIVE to that
# root. (Sending an absolute /srv/... path makes rrsync re-root it *under* the root →
# double-nested; verified.) Config in ~/.config/scrubjay/config:
#   SCRUBJAY_TRANSCRIPT_BACKEND="rsync-wg"
#   SCRUBJAY_WG_TARGET="scrubjay-rx@scrubjay-receiver"   # ssh destination ONLY — no remote path
#   SCRUBJAY_WG_SSHKEY="$HOME/.ssh/scrubjay_transcripts_ed25519"
# Per-machine reachability (HostName/Port/User) lives in the ~/.ssh/config 'scrubjay-receiver'
# alias, so this line stays identical on every machine.
transport_ship() {  # transport_ship <src> <relpath> [mirror]   (src may be a file or a directory)
  local src="$1" relpath="$2" mode="${3:-}"
  if [ -z "${SCRUBJAY_WG_TARGET:-}" ]; then
    echo "rsync-wg: SCRUBJAY_WG_TARGET unset — backend inactive" >&2; return 0
  fi
  local key="${SCRUBJAY_WG_SSHKEY:-$HOME/.ssh/id_ed25519}"
  local ssh="ssh -i $key -o StrictHostKeyChecking=accept-new"
  # mirror: --delete makes the receiver dir an exact copy of src (drops renamed/stale plans). It
  #   rides the rrsync protocol so it works even with the write-only receiver; if rrsync refuses
  #   the option the whole rsync is a no-op (|| true), degrading to the old additive behaviour.
  local del=""; [ "$mode" = mirror ] && del="--delete"
  # --no-perms: don't clone the source's restrictive transcript mode onto the receiver. It does
  #   NOT widen perms (rsync stamps the dest at the source mode; a umask can only remove bits) —
  #   the receiver's sj-receive.sh forced-command wrapper is what chmods the archive
  #   group-readable after each push, so the human + MCP server can read it. relpath is relative
  #   to the receiver's rrsync root; --mkpath creates it.
  # Return the real rsync exit code so a broken relay (e.g. an unauthorized key on the receiver)
  # is detectable by the caller — ship-transcript.sh records it as a breadcrumb. Still never
  # aborts the caller (it's not `set -e`). Mirror mode is the one exception: it rides rrsync's
  # OPTIONAL --delete, so a refusal there must degrade silently, not read as a relay failure.
  local rc=0
  if [ -d "$src" ]; then                       # directory: trailing slashes mirror contents into <relpath>/
    rsync -a --no-perms --mkpath $del -e "$ssh" "$src/" "$SCRUBJAY_WG_TARGET:$relpath/" 2>/dev/null || rc=$?
  else
    rsync -a --no-perms --mkpath -e "$ssh" "$src" "$SCRUBJAY_WG_TARGET:$relpath" 2>/dev/null || rc=$?
  fi
  [ "$mode" = mirror ] && rc=0
  return $rc
}

# --- read side (session hand-off) -------------------------------------------------------------
# The relay key CANNOT read: the receiver pins it to `rrsync -wo` (write-only) on purpose, so a
# stolen relay key can never exfiltrate the archive. That property stays. Reading back therefore
# rides the OTHER key this host already has — the one pinned to bin/sjmcp-serve.sh, which is
# read-only, confined to the archive roots, and already able to hand out raw .jsonl via
# sj_get(format="raw"). We are not widening what that key may see, only how it says it:
#   ssh <alias> resolve <sid>      -> TSV: <relpath> <lines> <mtime>
#   ssh <alias> fetch   <relpath>  -> a tar stream of that file or directory
# A host with no SCRUBJAY_MCP_REMOTE has no read channel at all; say so, and point at the script
# that grants one, rather than failing obscurely.
_wg_mcp_remote() {
  if [ -z "${SCRUBJAY_MCP_REMOTE:-}" ]; then
    echo "rsync-wg: the relay is write-only; reading the archive needs the sjmcp SSH channel." >&2
    echo "          Run bin/onboard-mcp-client.sh on this host to set SCRUBJAY_MCP_REMOTE." >&2
    return 1
  fi
  printf '%s' "$SCRUBJAY_MCP_REMOTE"
}

transport_resolve() {  # transport_resolve <sid|sid8>  -> TSV: <relpath> <lines> <mtime>
  local alias; alias="$(_wg_mcp_remote)" || return 1
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$alias" "resolve $1" 2>/dev/null
}

transport_fetch() {    # transport_fetch <relpath> <dst>   (relpath may be a file or a directory)
  local rel="$1" dst="$2" alias tmp rc=0
  alias="$(_wg_mcp_remote)" || return 1
  case "$rel" in /*|*..*) echo "rsync-wg: refusing unsafe archive path '$rel'" >&2; return 2 ;; esac
  tmp="$(mktemp -d)" || return 1
  # One tar stream covers both a file and a directory, so the caller doesn't have to know which.
  if ! ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$alias" "fetch $rel" 2>/dev/null \
       | tar -C "$tmp" -xf - 2>/dev/null; then rm -rf "$tmp"; return 1; fi
  if   [ -d "$tmp/$rel" ]; then mkdir -p "$dst" && cp -a "$tmp/$rel/." "$dst/" || rc=1
  elif [ -f "$tmp/$rel" ]; then mkdir -p "$(dirname "$dst")" && cp -f "$tmp/$rel" "$dst" || rc=1
  else rc=1; fi
  rm -rf "$tmp"; return $rc
}
