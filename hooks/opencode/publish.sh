#!/usr/bin/env bash
# Publish one opencode session: export it, then hand it to the shared SessionEnd hook.
#
# WHY THIS IS A SCRIPT AND NOT PART OF THE PLUGIN: opencode fires `session.idle` and then, in
# non-interactive `opencode run`, exits about 70ms later — it does not wait for plugin event
# handlers. An `opencode export` takes ~1s, so a publish done inside the plugin is killed mid-flight
# and the session is silently never archived. So the plugin only *launches* this, and the first
# thing we do is detach into our own session (setsid/nohup, the same dance hooks/log-session.sh does
# for Claude's SessionEnd) so the work outlives the opencode process that started it.
#
#   usage: publish.sh <session-id> [cwd]        (env: SCRUBJAY_OPENCODE_BIN, SCRUBJAY_NOSHIP)
#
# Idempotent: `session.idle` fires after every turn, so we fingerprint each export and skip one that
# is identical to the last we shipped for this session.
set -uo pipefail

if [ "${1:-}" != "--detached" ]; then
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  # Re-exec through `bash` rather than running $self directly: if the executable bit is ever lost
  # (an odd umask, a noexec mount, a zip download), a bare `setsid "$self"` fails with "permission
  # denied" — straight into /dev/null, so the bridge goes silently dead. Detaching must not depend
  # on a file mode.
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$self" --detached "$@" >/dev/null 2>&1 &
  else
    nohup bash "$self" --detached "$@" >/dev/null 2>&1 &
  fi
  exit 0
fi
shift   # drop --detached

sid="${1:?session id}"; cwd="${2:-$PWD}"
[ "${SCRUBJAY_NOSHIP:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
APP="$(cd "$(dirname "$self")/../.." 2>/dev/null && pwd)" || exit 0

# The plugin passes opencode's own binary path: it is not necessarily on PATH (the installer puts it
# in ~/.opencode/bin, which a desktop launcher may never have sourced).
OC="${SCRUBJAY_OPENCODE_BIN:-opencode}"
command -v "$OC" >/dev/null 2>&1 || exit 0

dir="${TMPDIR:-/tmp}/scrubjay-opencode"
mkdir -p "$dir" 2>/dev/null || exit 0
# The basename IS the session id — hooks/publish-now.sh reads it back off the path.
out="$dir/$sid.json"

# No --sanitize: scrubjay archives the real conversation to your own storage, and a redacted
# transcript would be worthless to resume from.
"$OC" export "$sid" > "$out" 2>/dev/null || exit 0
[ -s "$out" ] && jq empty "$out" 2>/dev/null || { rm -f "$out"; exit 0; }

# Idle fires after every turn; only the ones that actually changed the session are worth relaying
# (and, on the git backend, a commit).
sum="$(md5sum "$out" 2>/dev/null | cut -d' ' -f1)"
stamp="$dir/$sid.sum"
if [ -n "$sum" ] && [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$sum" ]; then exit 0; fi

# The same payload Claude Code hands a SessionEnd hook. `--detached` runs the work inline — we are
# already detached, so there is nothing left to outlive.
jq -nc --arg s "$sid" --arg c "$cwd" --arg t "$out" \
      '{session_id: $s, cwd: $c, transcript_path: $t}' \
  | SCRUBJAY_HARNESS=opencode bash "$APP/hooks/log-session.sh" --detached

[ -n "$sum" ] && printf '%s' "$sum" > "$stamp"
exit 0
