#!/usr/bin/env bash
# sj-snapshot.sh keeps recoverable history of the archive via zfs/btrfs snapshots. It is root-only
# and filesystem-side-effecting, so the suite exercises the PURE parts — filesystem detection (with
# findmnt stubbed), the snapshot name, and the prune math — plus a --dry-run run that must print the
# real command without touching anything. Real zfs/btrfs calls stay behind --dry-run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
export SCRUBJAY_SNAP_LIB=1; . "$APP/bin/sj-snapshot.sh"; unset SCRUBJAY_SNAP_LIB

# A findmnt stub: FSTYPE query → $FAKE_FSTYPE, SOURCE query → $FAKE_SOURCE. Also a no-op zfs.
STUB="$SANDBOX/stubbin"; mkdir -p "$STUB"
cat > "$STUB/findmnt" <<'EOF'
#!/usr/bin/env bash
case "$*" in *FSTYPE*) echo "${FAKE_FSTYPE:-zfs}";; *SOURCE*) echo "${FAKE_SOURCE:-pool/ds}";; esac
EOF
cat > "$STUB/zfs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB/findmnt" "$STUB/zfs"
export PATH="$STUB:$PATH"

section "filesystem detection (zfs / btrfs / neither)"
assert_eq "zfs mount → zfs"      "zfs"   "$(FAKE_FSTYPE=zfs   sjs_detect_fs /x)"
assert_eq "btrfs mount → btrfs"  "btrfs" "$(FAKE_FSTYPE=btrfs sjs_detect_fs /x)"
assert_eq "ext4 mount → none"    "none"  "$(FAKE_FSTYPE=ext4  sjs_detect_fs /x)"

section "snapshot name + prune math"
assert_eq "snapname is scrubjay-<ts>" "scrubjay-20260715-2230" "$(sjs_snapname 20260715-2230)"
# keep the newest 2 of 4 → the 2 oldest are pruned, newest-first ignored
pruned="$(printf '%s\n' \
  pool/ds@scrubjay-20260715-2200 pool/ds@scrubjay-20260715-2100 \
  pool/ds@scrubjay-20260715-2300 pool/ds@scrubjay-20260715-2000 | sjs_prune_list 2)"
assert_eq "prune drops exactly the two oldest" \
  "pool/ds@scrubjay-20260715-2100
pool/ds@scrubjay-20260715-2000" "$pruned"
assert_eq "keep >= count prunes nothing" "" \
  "$(printf '%s\n' pool/ds@scrubjay-20260715-2300 | sjs_prune_list 5)"

section "generated systemd units reference this script + path"
svc="$(sjs_service_text /opt/sj/bin/sj-snapshot.sh /mnt/nas1/scrubjay-storage 48)"
assert_contains "service ExecStart runs --now" "$svc" "sj-snapshot.sh --path /mnt/nas1/scrubjay-storage --keep 48 --now"
assert_contains "timer installs to timers.target" "$(sjs_timer_text hourly)" "WantedBy=timers.target"

section "--now --dry-run prints the real command but touches nothing"
out="$(FAKE_FSTYPE=zfs FAKE_SOURCE=pool/ds bash "$APP/bin/sj-snapshot.sh" --now --dry-run --path /mnt/nas1/scrubjay-storage 2>&1)"
assert_contains "dry-run echoes the zfs snapshot command" "$out" "+ zfs snapshot pool/ds@scrubjay-"
assert_contains "dry-run still prints the snapshot≠backup note" "$out" "not an off-box backup"

section "a non-snapshot filesystem fails loudly with guidance"
check_fails "ext4 storage is refused, not silently skipped" \
  env FAKE_FSTYPE=ext4 bash "$APP/bin/sj-snapshot.sh" --now --dry-run --path /x

finish
