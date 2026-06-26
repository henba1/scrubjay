#!/usr/bin/env bash
# Transport-agnostic entry point for relaying a Claude session's artifacts:
#   1) the transcript                     -> <host>/<slug>/<session>.jsonl
#   2) this session's subagent dir (if any: subagent transcripts, tool-results)
#                                          -> <host>/<slug>/<session>/
#   3) all plan files for this host       -> <host>/plans/
# (2) and (3) are full conversation / sensitive content, so they ride the same
# (P2P) backend as the transcript — never a separate third-party path.
#   usage: ship-transcript.sh <transcript_path> <slug> <session_id> [host]
# Selects $DOTCLAUDE_TRANSCRIPT_BACKEND (default: git). Each backend lives in
# hooks/transports/<backend>.sh and must define:  transport_ship <src> <relpath>
# (src may be a file or a directory).
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

# 1) the transcript itself: <host>/<project-slug>/<session>.jsonl
transport_ship "$src" "$host/$slug/$sid.jsonl"

# 2) this session's subagent artifacts (subagent transcripts, tool-results), if present.
#    They sit in a sibling dir named after the session id, next to <session>.jsonl.
sess_dir="$(dirname "$src")/$sid"
[ -d "$sess_dir" ] && transport_ship "$sess_dir" "$host/$slug/$sid"

# 3) plan files (sensitive; not session-keyed) — first give them meaningful <date>_<topic>.md
#    names in place (Claude Code names plans with three random words), then mirror the whole
#    small plans/ dir. Renaming is idempotent, so already-dated names survive across ships.
#    Derive the Claude config root from the transcript path (…/<root>/projects/<slug>/…).
claude_root="${src%/projects/*}"
if [ "$claude_root" != "$src" ] && [ -d "$claude_root/plans" ]; then
  dc_normalize_plans "$claude_root/plans"
  transport_ship "$claude_root/plans" "$host/plans"
fi

# 4) human-readable rendering (clean conversation) → <host>/readable/<project>/<date>_<topic>__<sid8>.md
#    Additive: machine .jsonl tree above is untouched; this is the browsable layer.
rel="$(dc_readable_relpath "$src" "$sid")"
tmpmd="$(mktemp 2>/dev/null)" || tmpmd=""
if [ -n "$tmpmd" ]; then
  bash "$APP/bin/render-transcript.sh" "$src" > "$tmpmd" 2>/dev/null
  [ -s "$tmpmd" ] && transport_ship "$tmpmd" "$host/readable/$rel.md"
  rm -f "$tmpmd"
fi
