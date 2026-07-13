#!/usr/bin/env bash
# Apply the synced config into every coding harness this machine uses ($SCRUBJAY_HARNESSES,
# default: claude). The per-harness work — which scopes get symlinked, how settings are merged,
# how the sjmcp archive server is registered — belongs to bin/adapters/<harness>.sh.
#
# Each adapter runs in its OWN subshell: the sjh_* functions share one namespace, so sourcing two
# adapters into the same shell would silently leave the second one's definitions in charge.
#
#   usage: sync-config.sh [--host NAME] [--force] [--version]   (flags are passed to each adapter)
#
# This is what SessionStart runs. `bin/claude-sync.sh` is still the Claude adapter's implementation
# and can be called directly; it just no longer speaks for every harness.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"

case "${1:-}" in
  -v|--version) echo "scrubjay $(sj_version)"; exit 0;;
  -h|--help)    echo "usage: sync-config.sh [--host NAME] [--force]"; exit 0;;
esac

read -r -a harnesses <<< "$(sj_harnesses)"
[ "${#harnesses[@]}" -gt 0 ] || { echo "sync-config: SCRUBJAY_HARNESSES is empty" >&2; exit 1; }

rc=0
for h in "${harnesses[@]}"; do
  # Only announce the harness when there is more than one — a single-harness machine (the norm)
  # should read exactly as it did before this became a loop.
  [ "${#harnesses[@]}" -gt 1 ] && printf '\n=== harness: %s ===\n' "$h"
  ( sj_load_adapter "$h" && sjh_apply_config "$@" ) || rc=1
done
exit "$rc"
