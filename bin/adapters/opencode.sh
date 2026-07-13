#!/usr/bin/env bash
# Harness adapter: opencode. Source this; do not execute. See bin/adapters/README.md.
#
# opencode differs from Claude Code in the three ways that matter here, and the adapter exists to
# absorb exactly those:
#
#   1) No lifecycle hooks. It has a plugin API instead, so scrubjay's SessionStart/SessionEnd are
#      driven by hooks/opencode/scrubjay.js — a shim that calls the same two hook scripts. There is
#      no "session ended" event (the closest is session.idle, which fires when the agent goes
#      quiet), so a session is shipped REPEATEDLY and idempotently rather than once at the end.
#      That is strictly crash-safer than waiting for an exit that a killed TUI never sends.
#   2) A session is not a file. It lives in opencode's database; `opencode export <sid>` prints the
#      whole thing as one JSON document ({info, messages:[{info, parts:[…]}]}). That export is what
#      we archive — hence a `.json` transcript, not `.jsonl`.
#   3) Session ids are `ses_<base62>`, not UUIDs, so the 8-char handle strips the prefix (the first
#      8 characters of the raw id would be "ses_" plus 4 real ones).
#
# The payoff of (2) is that `opencode import <file>` ingests that same export and re-homes it to the
# current project — so the archive holds a natively re-importable session.

sjh_config_dir() { printf '%s' "${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"; }
sjh_present()    { command -v opencode >/dev/null 2>&1; }

sjh_transcript_ext() { printf 'json'; }

# `ses_66a71b6f…` -> `66a71b6f`. Used for the readable filename and as the handle you search by;
# sj_archive_resolve matches it as a substring of the archived `<sid>.json`.
sjh_session_handle() { local s="${1#ses_}"; printf '%.8s' "$s"; }

# opencode has no project-dir slug of its own (sessions are rows, not files), so scrubjay picks
# one: the same lossy encoding Claude uses, over the session's directory. That keeps one archive
# layout — <host>/<slug>/<sid>.<ext> — across every harness.
sjh_slug()         { printf '%s' "$1" | sed 's/[^A-Za-z0-9-]/-/g'; }
sjh_session_slug() { local cwd="$2"; [ -n "$cwd" ] || cwd="$(sjh_session_cwd "$1")"; sjh_slug "$cwd"; }

sjh_session_cwd() { jq -r '.info.directory // ""' "$1" 2>/dev/null; }

# First real user prompt, one line. Text parts flagged `synthetic` (opencode's own injected context)
# or `ignored` are not the user talking, so they are skipped — the same cut sj_session_topic makes
# for Claude's `<system-reminder>` blocks.
sjh_session_topic() {  # sjh_session_topic <export.json>
  jq -r '[ .messages[]? | select(.info.role == "user") | .parts[]?
           | select(.type == "text" and (.synthetic | not) and (.ignored | not))
           | .text | select(. != null and . != "") ][0] // ""' "$1" 2>/dev/null \
    | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//'
}

sjh_render() { bash "$(sj_app)/bin/render-opencode.sh" "$1"; }

# Nothing yet. opencode keeps no plans/, no per-session task list and no file-history tree of its
# own, so the export IS the session. (Its snapshots live in git, not in a sidecar dir.)
sjh_extra_artifacts() { :; }

# --- config ------------------------------------------------------------------------------------
# Phase 1 registers the plugin and nothing else: opencode loads plugins from the `plugin` array in
# its config, and a spec may be an absolute path (packages/opencode/src/plugin/shared.ts). We point
# it straight at the file IN THE APP REPO rather than copying/symlinking it into the config dir, so
# `git pull` self-updates the bridge exactly like the hooks/ symlink does for Claude.
#
# Full config sync (AGENTS.md, agents/, commands/, the settings merge, MCP registration) is not
# wired up yet — see the roadmap. This must stay idempotent and must never clobber the user's file.
sjh_apply_config() {
  local cfgdir plugin cfg tmp
  cfgdir="$(sjh_config_dir)"
  plugin="$(sj_app)/hooks/opencode/scrubjay.js"
  cfg="$cfgdir/opencode.json"

  echo "opencode: $cfgdir"
  if ! command -v jq >/dev/null 2>&1; then echo "  SKIP  jq not on PATH"; return 0; fi
  [ -f "$plugin" ] || { echo "  SKIP  bridge plugin missing: $plugin"; return 0; }

  mkdir -p "$cfgdir" || return 1
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  if ! jq empty "$cfg" 2>/dev/null; then
    echo "  SKIP  $cfg is not valid JSON — fix it by hand, then rerun (refusing to overwrite)"
    return 0
  fi

  tmp="$(mktemp)" || return 1
  # Add our plugin to the array if it isn't already there; leave every other key untouched.
  jq --arg p "$plugin" '.plugin = ((.plugin // []) + [$p] | unique)' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$cfg"; then echo "  ok    plugin registered (scrubjay.js)"; rm -f "$tmp"
  else mv "$tmp" "$cfg"; echo "  add   plugin -> $plugin"; fi
}

# --- session hand-off --------------------------------------------------------------------------
# A session is a row in opencode's database, so it cannot simply be dropped into place the way a
# Claude transcript can. `opencode import <file>` is the supported way in — it reads exactly the
# export we archive and re-homes it onto the current project. So the hand-off stages the (path-
# rewritten) export into an inbox, and the resume command imports it. See the roadmap: making
# sj-resume run the import itself is the remaining polish.
sjh_project_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/scrubjay/inbox/opencode"; }
sjh_import_side() { :; }   # no sidecar records to restore — the export is self-contained
sjh_resume_cmd()  {  # sjh_resume_cmd <sid> <staged-file>
  printf 'opencode import %s   &&   opencode --session %s' "$2" "$1"
}

# opencode's transcript is not a file on disk, so there is nothing to point /sjlog at: the plugin
# exports the live session on demand instead (hooks/opencode/scrubjay.js).
sjh_find_live_transcript() { :; }
