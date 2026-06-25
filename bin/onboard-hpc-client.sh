#!/usr/bin/env bash
# Onboard an HPC login node as a dotclaude transcript client that ships over SSH,
# ProxyJumping through a home edge/bastion to the receiver. HPC nodes usually can't run
# WireGuard (no root/TUN; outbound UDP commonly blocked), so the transport rides TCP/SSH.
#
# Run ON the HPC node. Idempotent. It:
#   1. generates a passphraseless relay key if absent (forced-command restricted on the far
#      end, so a leak can only append transcripts — see the edge/receiver authorized_keys);
#   2. writes marker-bounded blocks into ~/.ssh/config (bastion + receiver via ProxyJump);
#   3. prepares the rsync-wg backend pointer in ~/.config/dotclaude/config;
#   4. prints the egress IP, the public key, and the two authorized_keys lines to install.
# It does NOT flip the active transcript backend unless --activate is given, so the node
# keeps shipping via its current backend until the home side is verified.
#
# Required:
#   --bastion-host H    public DDNS/host of the edge node (what the public port maps to)
#   --bastion-port P    public TCP port that reaches the edge node's sshd
#   --bastion-user U    jump user on the edge node
#   --receiver-host H   receiver address as seen FROM the edge node (its LAN IP)
# Optional:
#   --receiver-port P   receiver sshd port (as seen from the bastion; omit = ssh default 22)
#   --receiver-user U   default: claude-rx
#   --receiver-path P   rrsync root on the receiver (default: /srv/claude-chats)
#   --alias A           ssh_config Host alias for the receiver (default: claude-receiver)
#   --key F             relay key path (default: ~/.ssh/claude_transcripts_ed25519)
#   --activate          set DOTCLAUDE_TRANSCRIPT_BACKEND=rsync-wg now (default: leave as-is)
set -euo pipefail

RECEIVER_USER=claude-rx; RECEIVER_PATH=/srv/claude-chats; ALIAS=claude-receiver
KEY="$HOME/.ssh/claude_transcripts_ed25519"; ACTIVATE=0
BASTION_HOST=; BASTION_PORT=; BASTION_USER=; RECEIVER_HOST=; RECEIVER_PORT=
while [ $# -gt 0 ]; do case "$1" in
  --bastion-host) BASTION_HOST="$2"; shift 2;;
  --bastion-port) BASTION_PORT="$2"; shift 2;;
  --bastion-user) BASTION_USER="$2"; shift 2;;
  --receiver-host) RECEIVER_HOST="$2"; shift 2;;
  --receiver-port) RECEIVER_PORT="$2"; shift 2;;
  --receiver-user) RECEIVER_USER="$2"; shift 2;;
  --receiver-path) RECEIVER_PATH="$2"; shift 2;;
  --alias) ALIAS="$2"; shift 2;;
  --key) KEY="$2"; shift 2;;
  --activate) ACTIVATE=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
for v in BASTION_HOST BASTION_PORT BASTION_USER RECEIVER_HOST; do
  [ -n "${!v}" ] || { echo "ERROR: missing required flag (for $v)" >&2; exit 2; }
done
JUMP_ALIAS="${ALIAS}-jump"

# 1) relay key (passphraseless: the hook is non-interactive; far-end forced-command limits a leak)
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "dotclaude-transcripts $(hostname -s) -> $ALIAS" >/dev/null
  echo "generated relay key: $KEY"
else
  echo "relay key exists: $KEY (reusing)"
fi
chmod 600 "$KEY"

# 2) ssh_config: a marker-bounded block (idempotent — rewritten on each run)
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
B="# >>> dotclaude $ALIAS >>>"; E="# <<< dotclaude $ALIAS <<<"
tmp="$(mktemp)"; awk -v b="$B" -v e="$E" '
  $0==b{s=1} !s{print} $0==e{s=0}' "$CFG" > "$tmp"   # drop any prior block
{
  cat "$tmp"
  echo "$B"
  # StrictHostKeyChecking accept-new is set in BOTH blocks: a command-line -o does NOT reach
  # the ProxyJump hop, so each host needs its own policy (TOFU on first connect, then pinned).
  printf 'Host %s\n    HostName %s\n    Port %s\n    User %s\n    IdentityFile %s\n    IdentitiesOnly yes\n    StrictHostKeyChecking accept-new\n' \
    "$JUMP_ALIAS" "$BASTION_HOST" "$BASTION_PORT" "$BASTION_USER" "$KEY"
  printf 'Host %s\n    HostName %s\n' "$ALIAS" "$RECEIVER_HOST"
  [ -n "$RECEIVER_PORT" ] && printf '    Port %s\n' "$RECEIVER_PORT"   # receiver sshd port (omit => 22)
  printf '    User %s\n    IdentityFile %s\n    IdentitiesOnly yes\n    StrictHostKeyChecking accept-new\n    ProxyJump %s\n' \
    "$RECEIVER_USER" "$KEY" "$JUMP_ALIAS"
  echo "$E"
} > "$CFG.new" && mv "$CFG.new" "$CFG"; chmod 600 "$CFG"; rm -f "$tmp"
echo "wrote ssh_config blocks: $JUMP_ALIAS, $ALIAS"

# 3) dotclaude pointer: marker-bounded WG block (backend flipped only with --activate)
DCFG="$HOME/.config/dotclaude/config"; mkdir -p "$(dirname "$DCFG")"; touch "$DCFG"
BB="# >>> dotclaude wg >>>"; EE="# <<< dotclaude wg <<<"
tmp="$(mktemp)"; awk -v b="$BB" -v e="$EE" '$0==b{s=1} !s{print} $0==e{s=0}' "$DCFG" > "$tmp"
{
  cat "$tmp"
  echo "$BB"
  [ "$ACTIVATE" = 1 ] && echo ': "${DOTCLAUDE_TRANSCRIPT_BACKEND:=rsync-wg}"'
  echo ": \"\${DOTCLAUDE_WG_TARGET:=$RECEIVER_USER@$ALIAS:$RECEIVER_PATH}\""
  echo ": \"\${DOTCLAUDE_WG_SSHKEY:=$KEY}\""
  echo "$EE"
} > "$DCFG.new" && mv "$DCFG.new" "$DCFG"; rm -f "$tmp"
echo "wrote dotclaude WG pointer (backend $([ "$ACTIVATE" = 1 ] && echo 'ACTIVATED=rsync-wg' || echo 'unchanged — pass --activate to flip'))"

# 4) report: egress, pubkey, the lines to install at home
EGRESS="$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || true)"
PUB="$(cat "$KEY.pub")"
cat <<EOF

──────────────────────────────────────────────────────────────────────────────
 NEXT: install at home, then verify
──────────────────────────────────────────────────────────────────────────────
egress IP (allowlist the /24, not this single IP — login nodes round-robin):
  ${EGRESS:-<probe failed>}    -> suggest allow $(echo "${EGRESS:-0.0.0.0}" | sed 's/\.[0-9]*$/.0\/24/')

relay public key:
  $PUB

A) on the EDGE node — run onboard-edge-node.sh with:
   --hpc-pubkey "$PUB"
   --hpc-allow-cidr <that /24>   --receiver $RECEIVER_HOST:22

B) on the RECEIVER ($RECEIVER_HOST) — add to ~$RECEIVER_USER/.ssh/authorized_keys:
   restrict,command="rrsync -wo $RECEIVER_PATH" $PUB

VERIFY (after the home side + router port-forward are up):
   ssh $ALIAS true                                  # silent success via ProxyJump
   DOTCLAUDE_TRANSCRIPT_BACKEND=rsync-wg \\
   DOTCLAUDE_WG_TARGET=$RECEIVER_USER@$ALIAS:$RECEIVER_PATH \\
   ~/.dotclaude/dotclaude/bin/ship-transcript.sh <a-real.jsonl> testslug testsid \$(hostname -s)
THEN activate permanently:  re-run this script with --activate (or edit ~/.config/dotclaude/config)
──────────────────────────────────────────────────────────────────────────────
EOF
