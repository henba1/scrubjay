#!/usr/bin/env bash
# Set up a persistent mount of a NAS share for scrubjay's `local` transcript backend, then verify
# it is live and writable. Re-runnable and idempotent: generates a systemd .mount unit (or an
# /etc/fstab line) and, with confirmation, sudo-installs + mounts it; if you decline or there is no
# sudo, it prints the exact config + commands for you to apply by hand.
#
# It NEVER handles a CIFS password. For cifs it prints how to place a mode-600 credentials file
# yourself (the secrets analog of the receiver-side authorized_keys step) and references it from the
# mount options. NFS needs no credentials.
#
# Inputs (all preset-able so onboard.sh can drive it unattended):
#   SCRUBJAY_NAS_PROTO       nfs | cifs                      (default nfs)
#   SCRUBJAY_NAS_SERVER      NAS host/IP                     (required)
#   SCRUBJAY_NAS_EXPORT      export/share path on the NAS    (required, e.g. /export/scrubjay)
#   SCRUBJAY_NAS_MOUNTPOINT  where to mount it locally       (default /mnt/nas1)
#   SCRUBJAY_NAS_OPTS        extra mount options, comma-list (optional)
#   SCRUBJAY_NAS_CREDS       cifs credentials file           (default /etc/scrubjay-nas.creds)
#   SCRUBJAY_ASSUME_YES=1    install without prompting        (for unattended onboard)
#   SCRUBJAY_MOUNT_PRINT=1   never touch the system — print the config + steps only
#
# On success it creates <mountpoint>/scrubjay-storage and prints the path to feed
# SCRUBJAY_LOCAL_CHATS.  Sourcing with SCRUBJAY_MOUNT_LIB=1 defines the functions without running.
set -uo pipefail

# UI goes to stderr so stdout carries only the final storage path (LOCAL_CHATS=$(sj-mount.sh)).
info() { printf '\033[1;34m›\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── pure generators (no side effects — this is what tests assert on) ──────────────────────────

# The filesystem type passed to mount(8) for a protocol.
sjm_fstype() { case "$1" in nfs) printf 'nfs';; cifs) printf 'cifs';; *) printf '%s' "$1";; esac; }

# The mount source (`What=` / fstab field 1). NFS is server:/export; CIFS is //server/share.
sjm_what() {  # sjm_what <proto> <server> <export>
  case "$1" in
    cifs) printf '//%s%s' "$2" "$3" ;;      # //nas/scrubjay  (export begins with /)
    *)    printf '%s:%s' "$2" "$3" ;;        # nas:/export/scrubjay
  esac
}

# Mount options. `_netdev` makes the unit/fstab wait for the network at boot; the rest are sane
# defaults per protocol. CIFS references the credentials FILE — never an inline password — and maps
# ownership to the invoking user so the backend can write.
sjm_opts() {  # sjm_opts <proto> <creds-file> <uid> <gid> [extra]
  local proto="$1" creds="$2" uid="$3" gid="$4" extra="${5:-}" base
  case "$proto" in
    nfs)  base="_netdev,noatime,soft,timeo=150,retrans=3" ;;
    cifs) base="_netdev,noatime,credentials=$creds,uid=$uid,gid=$gid,iocharset=utf8,file_mode=0640,dir_mode=0750" ;;
    *)    base="_netdev,noatime" ;;
  esac
  [ -n "$extra" ] && base="$base,$extra"
  printf '%s' "$base"
}

# A tab-separated /etc/fstab line.
sjm_fstab_line() {  # sjm_fstab_line <what> <mountpoint> <fstype> <opts>
  printf '%s\t%s\t%s\t%s\t0\t0\n' "$1" "$2" "$3" "$4"
}

# A systemd .mount unit. systemd derives the unit name from Where=, so the file must be named to
# match (sjm_unit_name); the body just declares the mount and orders it after the network.
sjm_unit_text() {  # sjm_unit_text <what> <mountpoint> <fstype> <opts>
  cat <<UNIT
[Unit]
Description=scrubjay NAS mount ($2)
After=network-online.target
Wants=network-online.target

[Mount]
What=$1
Where=$2
Type=$3
Options=$4

[Install]
WantedBy=multi-user.target
UNIT
}

# The mandatory unit filename for a mountpoint (e.g. /mnt/nas1 -> mnt-nas1.mount).
sjm_unit_name() { systemd-escape -p --suffix=mount "$1"; }

# Do we drive systemd, or fall back to fstab?
sjm_use_systemd() { have systemd-escape && have systemctl; }

[ "${SCRUBJAY_MOUNT_LIB:-0}" = 1 ] && return 0 2>/dev/null || true

# ── main: assemble, install (guarded), verify ────────────────────────────────────────────────

PROTO="${SCRUBJAY_NAS_PROTO:-nfs}"
SERVER="${SCRUBJAY_NAS_SERVER:-}"
EXPORT="${SCRUBJAY_NAS_EXPORT:-}"
MP="${SCRUBJAY_NAS_MOUNTPOINT:-/mnt/nas1}"
EXTRA="${SCRUBJAY_NAS_OPTS:-}"
CREDS="${SCRUBJAY_NAS_CREDS:-/etc/scrubjay-nas.creds}"
YES="${SCRUBJAY_ASSUME_YES:-0}"
PRINT_ONLY="${SCRUBJAY_MOUNT_PRINT:-0}"

case "${1:-}" in
  -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}"; exit 0;;
esac

[ -n "$SERVER" ] || die "SCRUBJAY_NAS_SERVER is required (the NAS host/IP)."
[ -n "$EXPORT" ] || die "SCRUBJAY_NAS_EXPORT is required (the export/share path on the NAS)."
case "$PROTO" in nfs|cifs) : ;; *) die "SCRUBJAY_NAS_PROTO must be nfs or cifs (got '$PROTO')." ;; esac

FSTYPE="$(sjm_fstype "$PROTO")"
WHAT="$(sjm_what "$PROTO" "$SERVER" "$EXPORT")"
OPTS="$(sjm_opts "$PROTO" "$CREDS" "$(id -u)" "$(id -g)" "$EXTRA")"
STORAGE="$MP/scrubjay-storage"

info "NAS mount plan:"
printf '    %s  ->  %s   (%s)\n    options: %s\n' "$WHAT" "$MP" "$FSTYPE" "$OPTS" >&2

# CIFS: we never touch the password. Point at the credentials file and stop short of it.
if [ "$PROTO" = cifs ] && [ ! -f "$CREDS" ]; then
  warn "cifs needs a credentials file at $CREDS (this script will not create or read it)."
  cat >&2 <<EOF
    Create it yourself with root, mode 600:
      sudo install -m600 /dev/null $CREDS
      sudo tee $CREDS >/dev/null <<'CREDS'
      username=YOUR_NAS_USER
      password=YOUR_NAS_PASSWORD
      CREDS
    Then re-run this script.
EOF
  [ "$PRINT_ONLY" = 1 ] || die "no credentials file — placed it, then re-run."
fi

# Already mounted? Nothing to install; go straight to verify.
if mountpoint -q "$MP" 2>/dev/null; then
  ok "$MP is already a mount — skipping install."
else
  # Build the config text and choose the install method.
  if sjm_use_systemd; then
    UNIT_NAME="$(sjm_unit_name "$MP")"; UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
    UNIT_TEXT="$(sjm_unit_text "$WHAT" "$MP" "$FSTYPE" "$OPTS")"
    install_cmds() {
      printf '%s\n' "$UNIT_TEXT" | sudo tee "$UNIT_PATH" >/dev/null || return 1
      sudo mkdir -p "$MP" || return 1
      sudo systemctl daemon-reload || return 1
      sudo systemctl enable --now "$UNIT_NAME"
    }
    manual_steps() {
      { echo "  # write $UNIT_PATH:"; printf '%s\n' "$UNIT_TEXT" | sed 's/^/  /'
        echo "  sudo mkdir -p $MP"
        echo "  sudo systemctl daemon-reload && sudo systemctl enable --now $UNIT_NAME"; } >&2
    }
  else
    FSTAB_LINE="$(sjm_fstab_line "$WHAT" "$MP" "$FSTYPE" "$OPTS")"
    install_cmds() {
      sudo mkdir -p "$MP" || return 1
      grep -qF "	$MP	" /etc/fstab 2>/dev/null || printf '%s' "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null || return 1
      sudo mount "$MP"
    }
    manual_steps() {
      { echo "  # append to /etc/fstab:"; printf '  %s' "$FSTAB_LINE"
        echo "  sudo mkdir -p $MP && sudo mount $MP"; } >&2
    }
  fi

  do_install=0
  if [ "$PRINT_ONLY" = 1 ]; then
    :
  elif ! have sudo; then
    warn "sudo not available — printing the steps instead."
  elif [ "$YES" = 1 ]; then
    do_install=1
  elif [ -t 0 ] && { read -r -p "  install + mount now with sudo? [Y/n] " a || a=""; case "${a:-Y}" in [Yy]*|"") true;; *) false;; esac; }; then
    do_install=1
  fi

  if [ "$do_install" = 1 ]; then
    if install_cmds; then ok "mounted $MP"; else warn "install/mount failed — apply the steps by hand:"; manual_steps; fi
  else
    info "apply these steps with root, then re-run to verify:"; manual_steps
  fi
fi

# ── verify: live + writable (cures the silent 'backend inactive' no-op) ───────────────────────
if ! mountpoint -q "$MP" 2>/dev/null; then
  die "$MP is not a live mount — the local backend would silently no-op. Fix the mount, then re-run."
fi
mkdir -p "$STORAGE" 2>/dev/null || die "cannot create $STORAGE (mount not writable?)."
probe="$STORAGE/.sjwrite.$$"
if ( : > "$probe" ) 2>/dev/null; then rm -f "$probe"; else die "$STORAGE is not writable."; fi

ok "NAS mount verified. Set SCRUBJAY_LOCAL_CHATS=$STORAGE"
printf '%s\n' "$STORAGE"
