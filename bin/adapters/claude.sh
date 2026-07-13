#!/usr/bin/env bash
# Harness adapter: Claude Code. Source this; do not execute. See bin/adapters/README.md.
#
# This is scrubjay's original (and, for a long time, only) harness, so the adapter is mostly a
# home for behaviour that used to sit inline in the callers. Nothing here changed on the way in.

# Config root. CLAUDE_CONFIG_DIR is Claude Code's own override, so honour it.
sjh_config_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
sjh_present()    { command -v claude >/dev/null 2>&1; }

# Applying config is a big enough job to keep its own script (symlinked scopes, the settings.json
# merge, per-project memory links, MCP registration).
sjh_apply_config() { "$(sj_app)/bin/claude-sync.sh" "$@"; }

sjh_transcript_ext()  { printf 'jsonl'; }
sjh_session_handle()  { printf '%.8s' "$1"; }          # session ids are UUIDs: the first 8 hex
sjh_resume_cmd()      { printf 'claude --resume %s' "$1"; }   # ($2 = staged file; Claude reads it
                                                              #  in place, so it needs no import)

# Claude Code stores a session at <root>/projects/<slug>/<sid>.jsonl, where <slug> is the session's
# absolute cwd with every character outside [A-Za-z0-9-] replaced by '-'. The encoding is LOSSY (a
# '-' may have been '/', '_', '.' or a space), so scrubjay never decodes a slug — it archives the
# one Claude used, verbatim, and recomputes a *local* one when importing.
sjh_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9-]/-/g'; }

# The slug a session archives under: the one Claude actually chose, read straight off the path.
sjh_session_slug() { basename "$(dirname "$1")"; }

# The ~/.claude/projects/ dir that holds sessions for <cwd> (default: $PWD). Prefer *asking the
# archive of local sessions* — find the dir whose transcripts record this cwd — because that is
# exact and survives the edge cases sjh_slug() cannot see (e.g. a symlinked home: snellius records
# cwd=/home/jvrijn/… but Claude slugged the resolved /gpfs/home2/jvrijn/…). Fall back to encoding
# the resolved path, which is all we can do for a project that has no sessions on this host yet.
sjh_project_dir() {  # sjh_project_dir [cwd]
  local cwd="${1:-$PWD}" proj d f real
  proj="$(sjh_config_dir)/projects"
  for d in "$proj"/*/; do
    [ -d "$d" ] || continue
    f="$(ls -t "$d"*.jsonl 2>/dev/null | head -1)" || continue
    [ -n "$f" ] || continue
    if grep -qF "\"cwd\":\"$cwd\"" "$f" 2>/dev/null; then printf '%s' "${d%/}"; return 0; fi
  done
  real="$(realpath -e "$cwd" 2>/dev/null || printf '%s' "$cwd")"
  printf '%s/%s' "$proj" "$(sjh_slug "$real")"
}

sjh_session_topic() { sj_session_topic "$1"; }
sjh_session_cwd()   { jq -rs '[ .[] | select(.cwd != null) | .cwd ][0] // ""' "$1" 2>/dev/null; }
sjh_render()        { bash "$(sj_app)/bin/render-transcript.sh" "$1"; }

# The session records that are NOT the transcript. Emitted as TSV so the caller stays
# harness-blind: <src> <relpath under <host>/> <mode>.
sjh_extra_artifacts() {  # sjh_extra_artifacts <transcript> <sid> <slug> <cwd>
  local src="$1" sid="$2" slug="$3" cwd="$4" root sess_dir
  _art() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }

  # 1) subagent artifacts (subagent transcripts, tool-results): a sibling dir named after the
  #    session id, next to <session>.jsonl.
  sess_dir="$(dirname "$src")/$sid"
  [ -d "$sess_dir" ] && _art "$sess_dir" "$slug/$sid"

  # The Claude config root, derived from the transcript path (…/<root>/projects/<slug>/…) rather
  # than from sjh_config_dir, so a transcript shipped from a non-default root (backfill) still
  # finds ITS siblings. Falls back to the path itself, which simply matches nothing below.
  root="${src%/projects/*}"

  # 2) plan files (sensitive; not session-keyed). Claude names plans with three random words, so
  #    give them meaningful <date>_<topic>.md names *in place* first — idempotent, so already-dated
  #    names survive across ships. `mirror` because the relay copy is authoritative: a plan shipped
  #    under its old random-word name and then renamed here must not linger as a stale duplicate.
  if [ "$root" != "$src" ] && [ -d "$root/plans" ]; then
    sj_normalize_plans "$root/plans"
    _art "$root/plans" "plans" mirror
  fi

  # 3) prompt history — every prompt typed across all projects. One growing file; latest wins.
  [ -f "$root/history.jsonl" ] && _art "$root/history.jsonl" "history.jsonl"

  # 4) this session's task list (TaskCreate items).
  [ -d "$root/tasks/$sid" ] && _art "$root/tasks/$sid" "$slug/$sid/tasks"

  # 5) this session's file history — the pre-edit copies Claude keeps so /rewind can undo its own
  #    edits. Without it a handed-off session can be resumed but not rewound. Same sensitivity class
  #    as the transcript (it holds source files), so it rides the same backend.
  [ -d "$root/file-history/$sid" ] && _art "$root/file-history/$sid" "$slug/$sid/file-history"

  # 6) the project's CLAUDE.local.md (personal, gitignored project rules — private paths, cluster
  #    details). Host-specific, so it's a one-way per-host archive next to the project's
  #    transcripts, NOT merged across machines like memory. Lives in the working tree, not the
  #    config root.
  [ -n "$cwd" ] && [ -f "$cwd/CLAUDE.local.md" ] && _art "$cwd/CLAUDE.local.md" "$slug/CLAUDE.local.md"

  unset -f _art
  return 0
}

# Put a handed-off session's sidecar records back where Claude Code expects them: tasks/ and
# file-history/ live under the config root keyed by session id, everything else (subagent
# transcripts, tool results) sits beside the transcript in the project dir. <dir> is the fetched
# <host>/<slug>/<sid>/ subtree; it is consumed (emptied) as we go.
sjh_import_side() {  # sjh_import_side <sid> <dir> <project_dir>
  local sid="$1" dir="$2" proj="$3" root; root="$(sjh_config_dir)"
  [ -d "$dir" ] || return 0
  if [ -d "$dir/tasks" ]; then
    mkdir -p "$root/tasks/$sid" && cp -a "$dir/tasks/." "$root/tasks/$sid/" \
      && echo "  ✓  restored task list"
  fi
  if [ -d "$dir/file-history" ]; then
    mkdir -p "$root/file-history/$sid" && cp -a "$dir/file-history/." "$root/file-history/$sid/" \
      && echo "  ✓  restored file history (/rewind will work)"
  fi
  rm -rf "$dir/tasks" "$dir/file-history"
  if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    mkdir -p "$proj/$sid" && cp -a "$dir/." "$proj/$sid/" \
      && echo "  ✓  restored subagent transcripts + tool results"
  fi
}

# The transcript of the session running RIGHT NOW in <cwd> — for /sjlog, which publishes without a
# hook payload to tell it. Newest transcript recording this cwd; newest overall as a fallback.
sjh_find_live_transcript() {  # sjh_find_live_transcript <cwd>
  local cwd="$1" proj t
  proj="$(sjh_config_dir)/projects"
  t="$(grep -lF "\"cwd\":\"$cwd\"" "$proj"/*/*.jsonl 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)"
  [ -n "$t" ] || t="$(ls -t "$proj"/*/*.jsonl 2>/dev/null | head -1)"
  [ -n "$t" ] && [ -f "$t" ] && printf '%s' "$t"
}
