#!/usr/bin/env bash
# Configure a home EDGE / bastion node to accept an HPC transcript client and ProxyJump it
# to the receiver — hardened. Run ON the edge node as root. Idempotent and safe-by-default:
#   * creates a dedicated jump user (key-only);
#   * installs a restricted authorized_keys: the key may ONLY open a tunnel to the receiver
#     (permitopen), no shell/pty/agent/X11 — so a leaked key is useless beyond the jump;
#   * writes an sshd drop-in SCOPED to the jump user (never touches your other access),
#     validated with `sshd -t`; reloads sshd only with --apply-sshd;
#   * EMITS an nftables allowlist for the HPC egress range; applies it only with --apply-nft
#     (a wrong firewall drop can lock you out, so review before applying).
#
# Required:
#   --hpc-pubkey "ssh-ed25519 AAAA... comment"   (or --hpc-pubkey-file FILE)
#   --hpc-allow-cidr 203.0.113.0/24              HPC egress range allowed to the SSH port
#   --receiver IP:PORT                           the only target the key may tunnel to
# Optional:
#   --jump-user U     default: claude-jump
#   --ssh-port P      port the bastion sshd listens on (default 22; the public forward maps here)
#   --apply-sshd      install + reload the sshd drop-in (else: write + validate only)
#   --apply-nft       load the nft allowlist now (else: write the snippet + print only)
set -euo pipefail

JUMP_USER=claude-jump; SSH_PORT=22; APPLY_SSHD=0; APPLY_NFT=0
HPC_PUBKEY=; HPC_PUBKEY_FILE=; HPC_CIDR=; RECEIVER=
while [ $# -gt 0 ]; do case "$1" in
  --hpc-pubkey) HPC_PUBKEY="$2"; shift 2;;
  --hpc-pubkey-file) HPC_PUBKEY_FILE="$2"; shift 2;;
  --hpc-allow-cidr) HPC_CIDR="$2"; shift 2;;
  --receiver) RECEIVER="$2"; shift 2;;
  --jump-user) JUMP_USER="$2"; shift 2;;
  --ssh-port) SSH_PORT="$2"; shift 2;;
  --apply-sshd) APPLY_SSHD=1; shift;;
  --apply-nft) APPLY_NFT=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root (sudo)" >&2; exit 2; }
[ -n "$HPC_PUBKEY_FILE" ] && HPC_PUBKEY="$(cat "$HPC_PUBKEY_FILE")"
for v in HPC_PUBKEY HPC_CIDR RECEIVER; do
  [ -n "${!v}" ] || { echo "ERROR: missing required flag (for $v)" >&2; exit 2; }
done
case "$RECEIVER" in *:*) :;; *) echo "ERROR: --receiver must be IP:PORT" >&2; exit 2;; esac
BLOB="$(awk '{print $2}' <<<"$HPC_PUBKEY")"
[ -n "$BLOB" ] || { echo "ERROR: could not parse pubkey" >&2; exit 2; }

# 1) jump user (key-only; no password set)
if ! id "$JUMP_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$JUMP_USER"; passwd -l "$JUMP_USER" >/dev/null
  echo "created jump user: $JUMP_USER (locked password)"
else echo "jump user exists: $JUMP_USER"; fi
HOMEDIR="$(getent passwd "$JUMP_USER" | cut -d: -f6)"

# 2) restricted authorized_keys: tunnel to the receiver ONLY, nothing else
install -d -m 700 -o "$JUMP_USER" -g "$JUMP_USER" "$HOMEDIR/.ssh"
AK="$HOMEDIR/.ssh/authorized_keys"; touch "$AK"
LINE="restrict,port-forwarding,permitopen=\"$RECEIVER\",command=\"/bin/false\" $HPC_PUBKEY"
tmp="$(mktemp)"; grep -vF "$BLOB" "$AK" 2>/dev/null > "$tmp" || true   # drop any prior copy of this key
echo "$LINE" >> "$tmp"; install -m 600 -o "$JUMP_USER" -g "$JUMP_USER" "$tmp" "$AK"; rm -f "$tmp"
echo "installed restricted authorized_keys -> permitopen=$RECEIVER, no shell"

# 3) sshd drop-in, scoped to the jump user (does NOT affect other users/accounts)
DROP=/etc/ssh/sshd_config.d/20-dotclaude-bastion.conf
cat > "$DROP" <<EOF
# dotclaude bastion — restrictions apply ONLY to $JUMP_USER
Match User $JUMP_USER
    PasswordAuthentication no
    PubkeyAuthentication yes
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    AllowTcpForwarding yes
    PermitOpen $RECEIVER
EOF
if sshd -t 2>/dev/null; then
  echo "wrote + validated $DROP"
  if [ "$APPLY_SSHD" = 1 ]; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload
    echo "reloaded sshd"
  else echo "  (not reloaded — re-run with --apply-sshd, or: systemctl reload ssh)"; fi
else
  echo "ERROR: sshd -t rejected the drop-in; removing it" >&2; rm -f "$DROP"; sshd -t; exit 1
fi

# 4) nftables allowlist for the HPC egress range -> the SSH port (print/file by default)
NFT=/etc/nftables.d/dotclaude-ssh-allow.nft; mkdir -p "$(dirname "$NFT")"
cat > "$NFT" <<EOF
# dotclaude: allow only the HPC egress range to the bastion SSH port.
# NOTE: a 'drop' in any nft table is final — review against your existing ruleset before
# loading so you don't lock yourself out (keep LAN/your own access allowed elsewhere).
table inet dotclaude {
  set hpc_ssh_allow { type ipv4_addr; flags interval; elements = { $HPC_CIDR } }
  chain input {
    type filter hook input priority -5; policy accept;
    tcp dport $SSH_PORT ip saddr @hpc_ssh_allow accept
    tcp dport $SSH_PORT ip saddr != @hpc_ssh_allow ip saddr != 192.168.0.0/16 drop
  }
}
EOF
echo "wrote nft snippet: $NFT"
if [ "$APPLY_NFT" = 1 ]; then
  nft -f "$NFT" && echo "  loaded nft table 'dotclaude'"
else
  echo "  (NOT loaded — review it, ensure LAN access stays open, then: nft -f $NFT)"
fi

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
 Edge node configured. Remaining:
 1. RECEIVER ($RECEIVER): add to ~claude-rx/.ssh/authorized_keys —
      restrict,command="rrsync -wo /srv/claude-chats" $HPC_PUBKEY
 2. Router: forward public TCP <port> -> THIS host:$SSH_PORT.
 3. From the HPC node:  ssh $([ "$SSH_PORT" = 22 ] || echo "-p$SSH_PORT ")claude-receiver true
──────────────────────────────────────────────────────────────────────────────
EOF
