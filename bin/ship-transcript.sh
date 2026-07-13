#!/usr/bin/env bash
# Transport-agnostic AND harness-agnostic entry point for relaying a session's records:
#   1) the transcript                     -> <host>/<slug>/<session>.<ext>
#   2) everything else the harness keeps  -> per sjh_extra_artifacts (subagent transcripts,
#      tool-results, plans, prompt history, this session's tasks + file-history, CLAUDE.local.md)
#   3) a human-readable Markdown rendering -> <host>/readable/<project>/<date>_<topic>__<sid8>.md
# These are full conversation / sensitive content, so they all ride the same (P2P) backend as the
# transcript — never a separate third-party path.
#
#   usage: ship-transcript.sh <transcript_path> <slug> <session_id> [host] [cwd]
#
# Two seams meet here:
#   * WHERE it goes — $SCRUBJAY_TRANSCRIPT_BACKEND (default: git). Backends live in
#     hooks/transports/<backend>.sh and define  transport_ship <src> <relpath> [mirror].
#   * WHAT there is to ship — $SCRUBJAY_HARNESS (default: claude). Adapters live in
#     bin/adapters/<harness>.sh; see bin/adapters/README.md.
# A harness whose transcript is not already a file on disk (opencode) exports it first and hands us
# the export — this script only ever wants a path.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

src="${1:?transcript path}"; slug="${2:?slug}"; sid="${3:?session id}"
host="${4:-$(sj_host)}"
cwd="${5:-}"                                   # session working dir (for project-root files)
[ -f "$src" ] || exit 0

backend="${SCRUBJAY_TRANSCRIPT_BACKEND:-git}"
impl="$APP/hooks/transports/$backend.sh"
[ -f "$impl" ] || { echo "ship-transcript: unknown backend '$backend'" >&2; exit 0; }
# shellcheck source=/dev/null  # backend chosen at runtime; see hooks/transports/<backend>.sh
. "$impl"

harness="$(sj_harness)"
sj_load_adapter "$harness" || exit 0

# 1) the transcript itself. This push is the canonical "is the relay working?" signal — record its
#    outcome as a machine-local breadcrumb so a silent failure (e.g. an unauthorized relay key) is
#    flagged at the next SessionStart, not days later.
transport_ship "$src" "$host/$slug/$sid.$(sjh_transcript_ext)"; ship_rc=$?
if [ "$ship_rc" -eq 0 ]; then sj_record_ship ok "$sid" "$backend"
else sj_record_ship fail "$sid" "$backend" "$ship_rc"; fi

# The session cwd: given by the hook payload, else recovered from the transcript.
[ -n "$cwd" ] || cwd="$(sjh_session_cwd "$src")"

# 2) the session's other records. The adapter names them; we just relay them. It may normalize
#    files in place first (Claude's plans get <date>_<topic>.md names), and may ask for `mirror`
#    to make the relay copy authoritative. A record that doesn't exist is skipped.
while IFS=$'\t' read -r a_src a_rel a_mode; do
  [ -n "$a_src" ] && [ -n "$a_rel" ] && [ -e "$a_src" ] || continue
  transport_ship "$a_src" "$host/$a_rel" ${a_mode:+"$a_mode"}
done < <(sjh_extra_artifacts "$src" "$sid" "$slug" "$cwd")

# 3) human-readable rendering (clean conversation). Additive: the machine-format tree above is
#    untouched; this is the browsable layer — and the one thing every harness has in common, which
#    is why /sjrecall and /sjbrowse can search across all of them.
rel="$(sj_readable_relpath "$src" "$sid" "$cwd" "$(sjh_session_topic "$src")")"
tmpmd="$(mktemp 2>/dev/null)" || tmpmd=""
if [ -n "$tmpmd" ]; then
  sjh_render "$src" > "$tmpmd" 2>/dev/null
  [ -s "$tmpmd" ] && transport_ship "$tmpmd" "$host/readable/$rel.md"
  rm -f "$tmpmd"
fi
