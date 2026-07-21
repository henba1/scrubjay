#!/usr/bin/env bash
# Snapshot durability for the scrubjay archive — run this WITH ROOT ON THE NAS (the box that holds
# scrubjay-storage). It is the receiver-side half of the `local` backend and, like the other
# root-owned steps (bin/sj-migrate.sh, the authorized_keys line), it stays yours: onboard never runs
# it. It keeps point-in-time, recoverable history of the append-only records WITHOUT paying git's
# blob tax — which is exactly why transcripts ride rsync/copy and not git (docs/concepts.md).
#
#   sj-snapshot.sh --now                 take one snapshot now (+ prune to --keep)
#   sj-snapshot.sh --schedule            install a systemd timer that snapshots on a schedule
#   sj-snapshot.sh --list                list scrubjay-* snapshots
#   sj-snapshot.sh --restore <snap>      PRINT the exact restore commands (never runs them)
#   flags: --path <dir> (default $SCRUBJAY_LOCAL_CHATS or /mnt/nas1/scrubjay-storage)
#          --keep N (default 48)  --oncalendar <spec> (default hourly)  --dry-run
#
# Works on zfs and btrfs (auto-detected). Snapshots are NOT an off-box backup — they live on the
# same disk. For disk-failure protection, replicate them (zfs send | ssh, btrbk, restic).
# Sourcing with SCRUBJAY_SNAP_LIB=1 defines the functions without running.
set -uo pipefail

info() { printf '\033[1;34m›\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── pure helpers (no side effects — the tested seam) ──────────────────────────────────────────

# The filesystem backing <path>, as scrubjay cares about it: zfs | btrfs | none.
sjs_detect_fs() {  # sjs_detect_fs <path>
  local t; t="$(findmnt -n -o FSTYPE --target "$1" 2>/dev/null)"
  case "$t" in zfs) printf zfs;; btrfs) printf btrfs;; *) printf none;; esac
}

# A snapshot name for a timestamp — sortable, greppable, unmistakably ours. The timestamp arg is
# optional (defaults to now); tests pass a fixed one.
# shellcheck disable=SC2120
sjs_snapname() { printf 'scrubjay-%s' "${1:-$(date +%Y%m%d-%H%M%S)}"; }

# Given a keep-count and a newline list of snapshot names on stdin (any order), print the ones to
# PRUNE — everything except the newest <keep>. Names sort lexically because the timestamp is fixed
# width, so `sort` is chronological.
sjs_prune_list() {  # sjs_prune_list <keep>   (names on stdin)
  local keep="$1"
  grep -E '(^|[@/])scrubjay-[0-9]' | sort -r | awk -v k="$keep" 'NR>k'
}

# The commands each filesystem uses (pure strings, so --dry-run can echo them verbatim).
sjs_zfs_snap_cmd()   { printf 'zfs snapshot %s@%s' "$1" "$2"; }              # <dataset> <name>
sjs_btrfs_snap_cmd() { printf 'btrfs subvolume snapshot -r %s %s/%s' "$1" "$2" "$3"; }  # <src> <snapdir> <name>

# systemd units for scheduled snapshots (generated, not hand-installed).
sjs_service_text() {  # sjs_service_text <self> <path> <keep>
  cat <<UNIT
[Unit]
Description=scrubjay archive snapshot ($2)

[Service]
Type=oneshot
ExecStart=$1 --path $2 --keep $3 --now
UNIT
}
sjs_timer_text() {  # sjs_timer_text <oncalendar>
  cat <<UNIT
[Unit]
Description=scrubjay archive snapshot timer

[Timer]
OnCalendar=$1
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

[ "${SCRUBJAY_SNAP_LIB:-0}" = 1 ] && return 0 2>/dev/null || true

# ── main ──────────────────────────────────────────────────────────────────────────────────────

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PATH_STORAGE="${SCRUBJAY_LOCAL_CHATS:-/mnt/nas1/scrubjay-storage}"
KEEP=48; ONCAL="hourly"; DRY="${SCRUBJAY_DRYRUN:-0}"; ACTION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --now)        ACTION=now;;
    --schedule)   ACTION=schedule;;
    --list)       ACTION=list;;
    --restore)    ACTION=restore; RESTORE_SNAP="${2:?--restore needs a snapshot name}"; shift;;
    --path)       PATH_STORAGE="${2:?}"; shift;;
    --keep)       KEEP="${2:?}"; shift;;
    --oncalendar) ONCAL="${2:?}"; shift;;
    --dry-run)    DRY=1;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}"; exit 0;;
    *)            die "unknown argument '$1' (see --help)";;
  esac
  shift
done
[ -n "$ACTION" ] || die "nothing to do — pass --now, --schedule, --list or --restore (see --help)."

run() { if [ "$DRY" = 1 ]; then printf '  + %s\n' "$*" >&2; else eval "$*"; fi; }

FS="$(sjs_detect_fs "$PATH_STORAGE")"
if [ "$FS" = none ]; then
  warn "$PATH_STORAGE is not on zfs or btrfs — filesystem snapshots aren't available here."
  info "options: put scrubjay-storage on a btrfs subvolume or zfs dataset, or use LVM snapshots / restic."
  exit 1
fi
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || warn "not root — zfs/btrfs operations will likely fail. Re-run with sudo on the NAS."

# Resolve the fs object once (dataset for zfs, subvolume dir for btrfs).
DATASET="$(findmnt -n -o SOURCE --target "$PATH_STORAGE" 2>/dev/null)"   # zfs: pool/dataset
SNAPDIR="$(dirname "$PATH_STORAGE")/.scrubjay-snapshots"                  # btrfs: where -r snapshots land

case "$ACTION" in
  now)
    name="$(sjs_snapname)"
    if [ "$FS" = zfs ]; then
      run "$(sjs_zfs_snap_cmd "$DATASET" "$name")"
    else
      run "mkdir -p $SNAPDIR"
      run "$(sjs_btrfs_snap_cmd "$PATH_STORAGE" "$SNAPDIR" "$name")"
    fi
    ok "snapshot $name ($FS)"
    # prune to --keep
    if [ "$FS" = zfs ]; then
      to_del="$(zfs list -H -t snapshot -o name 2>/dev/null | grep -F "$DATASET@" | sjs_prune_list "$KEEP")"
      for s in $to_del; do run "zfs destroy $s"; done
    else
      to_del="$(ls -1 "$SNAPDIR" 2>/dev/null | sjs_prune_list "$KEEP")"
      for s in $to_del; do run "btrfs subvolume delete $SNAPDIR/$s"; done
    fi
    [ -n "${to_del:-}" ] && ok "pruned to newest $KEEP" || true
    ;;
  schedule)
    have systemctl || die "no systemctl — install a cron job calling '$SELF --now' instead."
    svc=/etc/systemd/system/scrubjay-snapshot.service
    tmr=/etc/systemd/system/scrubjay-snapshot.timer
    run "printf '%s' \"\$(sjs_service_text '$SELF' '$PATH_STORAGE' '$KEEP')\" > $svc"
    run "printf '%s' \"\$(sjs_timer_text '$ONCAL')\" > $tmr"
    run "systemctl daemon-reload"
    run "systemctl enable --now scrubjay-snapshot.timer"
    ok "scheduled: $ONCAL, keep $KEEP → $tmr"
    ;;
  list)
    if [ "$FS" = zfs ]; then
      zfs list -t snapshot -o name,creation 2>/dev/null | grep -F "$DATASET@" || info "no snapshots yet"
    else
      # basename-only listing. `find -printf '%f\n'` would be shorter but is a GNU extension that
      # BSD find lacks outright — and this script also runs on a non-Linux NAS.
      snaps="$(find "$SNAPDIR" -maxdepth 1 -name 'scrubjay-[0-9]*' 2>/dev/null \
               | while IFS= read -r s; do basename "$s"; done | sort)"
      [ -n "$snaps" ] && printf '%s\n' "$snaps" || info "no snapshots yet"
    fi
    ;;
  restore)
    # Restore is destructive and filesystem-specific — PRINT the exact commands, never run them.
    warn "restore is destructive; review, then run these yourself with root on the NAS:"
    if [ "$FS" = zfs ]; then
      cat >&2 <<EOF
    # roll the dataset back to the snapshot (discards everything written since it):
    zfs rollback -r $DATASET@$RESTORE_SNAP
    #   — or, non-destructively, clone it elsewhere and copy what you need:
    zfs clone $DATASET@$RESTORE_SNAP ${DATASET%/*}/scrubjay-restore
EOF
    else
      cat >&2 <<EOF
    # the read-only snapshot is a full tree; copy what you need out of it:
    ls $SNAPDIR/$RESTORE_SNAP
    rsync -a $SNAPDIR/$RESTORE_SNAP/ $PATH_STORAGE/     # (review before overwriting!)
EOF
    fi
    ;;
esac

info "note: snapshots share the disk with the archive — they are not an off-box backup. For"
info "disk-failure protection, replicate them (zfs send | ssh, btrbk, or restic)."
