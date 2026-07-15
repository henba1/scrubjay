#!/usr/bin/env bash
# sj-mount.sh turns NAS share details into a persistent mount config (a systemd .mount unit or an
# /etc/fstab line) and verifies the result is live + writable. These generators are pure and
# side-effect-free — the sudo/systemctl install stays gated behind a confirm/ASSUME_YES flag — so
# the suite asserts the config it would apply (and that a cifs mount never embeds a password),
# without touching the system.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox   # for a clean $SANDBOX scratch dir (and an isolated $HOME)
export SCRUBJAY_MOUNT_LIB=1; . "$APP/bin/sj-mount.sh"; unset SCRUBJAY_MOUNT_LIB

section "mount source + fstype per protocol"
assert_eq "nfs source is server:/export" "nas1:/export/scrubjay" "$(sjm_what nfs nas1 /export/scrubjay)"
assert_eq "cifs source is //server/share" "//nas1/scrubjay" "$(sjm_what cifs nas1 /scrubjay)"
assert_eq "nfs fstype" "nfs" "$(sjm_fstype nfs)"
assert_eq "cifs fstype" "cifs" "$(sjm_fstype cifs)"

section "options: _netdev for boot ordering; cifs uses a credentials FILE, not a password"
assert_contains "nfs opts carry _netdev" "$(sjm_opts nfs /etc/x 1000 1000)" "_netdev"
copts="$(sjm_opts cifs /etc/scrubjay-nas.creds 1000 1000)"
assert_contains "cifs opts reference the creds file" "$copts" "credentials=/etc/scrubjay-nas.creds"
check_fails "cifs opts contain no inline password=" \
  bash -c 'printf "%s" "$1" | grep -qi "password="' _ "$copts"

section "systemd unit: name matches the mountpoint, body declares the mount"
assert_eq "unit name is derived from the mountpoint" "mnt-nas1.mount" "$(sjm_unit_name /mnt/nas1)"
unit="$(sjm_unit_text nas1:/export/scrubjay /mnt/nas1 nfs _netdev,noatime)"
assert_contains "unit Where= is the mountpoint" "$unit" "Where=/mnt/nas1"
assert_contains "unit What= is the source" "$unit" "What=nas1:/export/scrubjay"
assert_contains "unit orders after the network" "$unit" "After=network-online.target"

section "fstab fallback line"
fl="$(sjm_fstab_line nas1:/export /mnt/nas1 nfs _netdev,noatime)"
assert_contains "fstab line carries the mountpoint field" "$fl" "	/mnt/nas1	"
assert_contains "fstab line carries the fstype" "$fl" "	nfs	"

section "verify guard: a path that is not a live mount fails loudly (no silent no-op)"
check_fails "sj-mount refuses to finish when the mountpoint is not mounted" \
  env SCRUBJAY_MOUNT_LIB=0 SCRUBJAY_MOUNT_PRINT=1 SCRUBJAY_NAS_SERVER=nas1 \
      SCRUBJAY_NAS_EXPORT=/export/scrubjay SCRUBJAY_NAS_MOUNTPOINT="$SANDBOX/not-a-mount" \
      bash "$APP/bin/sj-mount.sh"

finish
