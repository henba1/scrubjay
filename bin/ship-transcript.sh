#!/usr/bin/env bash
# Transport-agnostic entry point for relaying a Claude session's artifacts:
#   1) the transcript                     -> <host>/<slug>/<session>.jsonl
#   2) this session's subagent dir (if any: subagent transcripts, tool-results)
#                                          -> <host>/<slug>/<session>/
#   3) all plan files for this host       -> <host>/plans/
#   …plus readable rendering, prompt history, this session's tasks, and the
#      project's CLAUDE.local.md (see numbered steps below).
# These are full conversation / sensitive content, so they ride the same
# (P2P) backend as the transcript — never a separate third-party path.
#   usage: ship-transcript.sh <transcript_path> <slug> <session_id> [host] [cwd]
# Selects $SCRUBJAY_TRANSCRIPT_BACKEND (default: git). Each backend lives in
# hooks/transports/<backend>.sh and must define:  transport_ship <src> <relpath>
# (src may be a file or a directory).
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

# 1) the transcript itself: <host>/<project-slug>/<session>.jsonl. This push is the canonical
#    "is the relay working?" signal — record its outcome as a machine-local breadcrumb so a silent
#    failure (e.g. an unauthorized relay key) is flagged at the next SessionStart, not days later.
transport_ship "$src" "$host/$slug/$sid.jsonl"; ship_rc=$?
if [ "$ship_rc" -eq 0 ]; then sj_record_ship ok "$sid" "$backend"
else sj_record_ship fail "$sid" "$backend" "$ship_rc"; fi

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
  sj_normalize_plans "$claude_root/plans"
  # `mirror`: the relay copy is an *exact* mirror of the (normalized) local plans/, so a plan
  #  that was shipped under its old random-word name and then renamed in place doesn't linger
  #  as a stale duplicate on the NAS.
  transport_ship "$claude_root/plans" "$host/plans" mirror
fi

# 4) human-readable rendering (clean conversation) → <host>/readable/<project>/<date>_<topic>__<sid8>.md
#    Additive: machine .jsonl tree above is untouched; this is the browsable layer.
rel="$(sj_readable_relpath "$src" "$sid")"
tmpmd="$(mktemp 2>/dev/null)" || tmpmd=""
if [ -n "$tmpmd" ]; then
  bash "$APP/bin/render-transcript.sh" "$src" > "$tmpmd" 2>/dev/null
  [ -s "$tmpmd" ] && transport_ship "$tmpmd" "$host/readable/$rel.md"
  rm -f "$tmpmd"
fi

# 5) prompt history (sensitive — every prompt typed across all projects) → per-host archive.
#    One growing file; latest copy wins. claude_root was derived in step 3.
[ -n "${claude_root:-}" ] && [ -f "$claude_root/history.jsonl" ] && \
  transport_ship "$claude_root/history.jsonl" "$host/history.jsonl"

# 6) this session's task list (TaskCreate items), if any → alongside the session's artifacts.
[ -n "${claude_root:-}" ] && [ -d "$claude_root/tasks/$sid" ] && \
  transport_ship "$claude_root/tasks/$sid" "$host/$slug/$sid/tasks"

# 6b) this session's file history — the pre-edit copies Claude Code keeps so /rewind can undo its
#     own edits. Without it a session handed off to another machine (bin/sj-resume.sh) can be
#     resumed but not rewound. Same sensitivity class as the transcript (it holds source files), so
#     it rides the same P2P backend, never a third party.
[ -n "${claude_root:-}" ] && [ -d "$claude_root/file-history/$sid" ] && \
  transport_ship "$claude_root/file-history/$sid" "$host/$slug/$sid/file-history"

# 7) the project's CLAUDE.local.md (personal, gitignored project rules — sensitive: holds private
#    paths/cluster details, and host-specific, so it's a one-way per-host archive next to the
#    project's transcripts, NOT merged across machines like memory). Lives in the working tree
#    root, not under ~/.claude, so we need the session cwd. Fall back to the transcript's own cwd.
[ -n "$cwd" ] || cwd="$(jq -r 'select(.cwd!=null) | .cwd' "$src" 2>/dev/null | head -1)"
[ -n "$cwd" ] && [ -f "$cwd/CLAUDE.local.md" ] && \
  transport_ship "$cwd/CLAUDE.local.md" "$host/$slug/CLAUDE.local.md"
