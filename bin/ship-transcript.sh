#!/usr/bin/env bash
# Transport-agnostic entry point for relaying a Claude transcript.
#   usage: ship-transcript.sh <transcript_path> <slug> <session_id> [host]
# Selects $DOTCLAUDE_TRANSCRIPT_BACKEND (default: git). Each backend lives in
# hooks/transports/<backend>.sh and must define:  transport_ship <src> <relpath>
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; dc_load_config

src="${1:?transcript path}"; slug="${2:?slug}"; sid="${3:?session id}"
host="${4:-$(dc_host)}"
[ -f "$src" ] || exit 0

backend="${DOTCLAUDE_TRANSCRIPT_BACKEND:-git}"
impl="$APP/hooks/transports/$backend.sh"
[ -f "$impl" ] || { echo "ship-transcript: unknown backend '$backend'" >&2; exit 0; }
. "$impl"

# Layout inside the relay: <host>/<project-slug>/<session>.jsonl
transport_ship "$src" "$host/$slug/$sid.jsonl"
