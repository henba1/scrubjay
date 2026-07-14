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

# Is <file> an opencode session export? One JSON *document* (not JSONL) that opens with the `info`
# object — `{"info":{"id":"ses_…`. Anchored on the head so a huge transcript is never parsed, with a
# whole-file parse as a fallback in case the key order ever changes.
sjh_detect() {  # sjh_detect <file>
  head -c 4096 "$1" 2>/dev/null | tr -d '[:space:]' | grep -q '^{"info":{' && return 0
  [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -lt 5000000 ] || return 1
  jq -e '.info.id | startswith("ses_")' "$1" >/dev/null 2>&1
}

# Nothing yet. opencode keeps no plans/, no per-session task list and no file-history tree of its
# own, so the export IS the session. (Its snapshots live in git, not in a sidecar dir.)
sjh_extra_artifacts() { :; }

# --- config ------------------------------------------------------------------------------------
# What we put into opencode's own config dir:
#   * the lifecycle bridge plugin  (opencode.json `plugin`)
#   * the sjmcp archive server     (opencode.json `mcp`)   -> /sjrecall & co. work INSIDE opencode
#   * the /sj* commands            (commands/*.md)
# NOT yet: AGENTS.md / agents/ / the settings merge — see the roadmap.
#
# Everything here is idempotent and additive: we never rewrite a key we don't own, and we bail
# rather than clobber a config we cannot parse.

# opencode loads a plugin from the `plugin` array, and a spec may be an absolute path
# (packages/opencode/src/plugin/shared.ts). Point it straight at the file IN THE APP REPO rather
# than copying it into the config dir, so `git pull` self-updates the bridge exactly like the
# hooks/ symlink does for Claude.
_sjh_oc_plugin_json() { jq -n --arg p "$(sj_app)/hooks/opencode/scrubjay.js" '[$p]'; }

# The sjmcp archive server, in opencode's `mcp` shape ({type:"local", command:[…], environment:{…}}).
# Same two modes claude-sync.sh registers, and for the same reasons:
#   LOCAL  — this box HAS the archive (a NAS mount, or the scrubjay-chats clone on the git backend):
#            run the stdio server here via uv.
#   REMOTE — it doesn't: `ssh <target>`, where a forced command (bin/sjmcp-serve.sh) runs the server
#            on the archive host and pipes MCP stdio back.
# Prints the server object, or nothing (with a reason on stdout) when neither mode is available.
_sjh_oc_mcp_json() {
  local chats remote server clone
  sj_load_config
  chats="${SCRUBJAY_LOCAL_CHATS:-}"; remote="${SCRUBJAY_MCP_REMOTE:-}"
  server="$(sj_app)/mcp/sjmcp_server.py"

  if [ -z "$chats" ] && [ -z "$remote" ] && [ "${SCRUBJAY_TRANSCRIPT_BACKEND:-}" = git ]; then
    clone="$(sj_chats)"
    [ -n "$clone" ] && [ -d "$clone/.git" ] && chats="$clone"
  fi

  if [ -n "$chats" ] && [ -d "$chats" ]; then
    command -v uv >/dev/null 2>&1 || {
      echo "  ┌─ MCP archive server NOT registered (/sjrecall, /sjfind, /sjbrowse stay inert)" >&2
      echo "  └─ reason: no 'uv' runtime on PATH — install uv, reopen your shell, rerun" >&2; return 1; }
    [ -f "$server" ] || { echo "  SKIP  mcp: server file missing: $server" >&2; return 1; }
    jq -n --arg s "$server" --arg chats "$chats" --arg mem "$(sj_memory)" --arg data "${SCRUBJAY_DATA:-}" \
      '{type: "local", command: ["uv", "run", "--script", $s], enabled: true,
        environment: {SCRUBJAY_LOCAL_CHATS: $chats, SCRUBJAY_MEMORY: $mem, SCRUBJAY_DATA: $data}}'
  elif [ -n "$remote" ]; then
    command -v ssh >/dev/null 2>&1 || { echo "  SKIP  mcp: no 'ssh' to reach $remote" >&2; return 1; }
    # No environment: the far-end forced command supplies the archive pointers. BatchMode so a
    # missing key fails fast instead of hanging the MCP transport on a password prompt.
    jq -n --arg t "$remote" \
      '{type: "local", enabled: true,
        command: ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", $t]}'
  else
    echo "  ┌─ MCP archive server NOT registered (/sjrecall, /sjfind, /sjbrowse stay inert)" >&2
    echo "  └─ reason: no local archive (SCRUBJAY_LOCAL_CHATS) and no remote (SCRUBJAY_MCP_REMOTE)" >&2
    return 1
  fi
}

# The /sj* commands, translated into opencode's dialect. Same prompts, same files — opencode reads
# the same markdown-with-frontmatter, takes the same $ARGUMENTS and the same !`shell` injection — so
# the translation is purely mechanical and the commands stay single-sourced in commands/:
#   * frontmatter keys opencode has no concept of (argument-hint, allowed-tools) are dropped;
#   * MCP tools are namespaced <server>_<tool>, not mcp__<server>__<tool>
#     (packages/opencode/src/mcp/catalog.ts: toolName);
#   * the app path is resolved here — a Claude command finds it by following the ~/.claude/hooks
#     symlink, which does not exist for opencode;
#   * every scrubjay script the command shells out to is prefixed with SCRUBJAY_HARNESS=opencode.
#     Without it, /sjlog and /sjresume would load the CLAUDE adapter — the scripts take the harness
#     from the environment, and opencode does not put it there (only the bridge plugin does, for its
#     own subprocesses). This is the one translation that is about correctness, not dialect.
# Files are GENERATED (regenerated on every sync), so edit commands/, never the copies.
_sjh_oc_commands() {
  local dst="$1" app src name n=0
  app="$(sj_app)"
  mkdir -p "$dst" || return 1
  for src in "$app"/commands/*.md; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    sed -E \
      -e '/^(argument-hint|allowed-tools):/d' \
      -e 's/mcp__sjmcp__/sjmcp_/g' \
      -e "s#\"\\\$\(cd .* && pwd\)/bin/#\"$app/bin/#g" \
      -e "s#~/\.claude/hooks/\.\./bin/#$app/bin/#g" \
      -e "s#~/\.claude/hooks/#$app/hooks/#g" \
      -e "s#bash \"$app/#SCRUBJAY_HARNESS=opencode bash \"$app/#g" \
      -e "s#bash $app/#SCRUBJAY_HARNESS=opencode bash $app/#g" \
      "$src" > "$dst/$name" || continue
    n=$((n + 1))
  done
  echo "  gen   $n commands -> $dst/"
}

sjh_apply_config() {
  local cfgdir cfg tmp mcp
  cfgdir="$(sjh_config_dir)"
  cfg="$cfgdir/opencode.json"

  echo "opencode: $cfgdir"
  command -v jq >/dev/null 2>&1 || { echo "  SKIP  jq not on PATH"; return 0; }
  [ -f "$(sj_app)/hooks/opencode/scrubjay.js" ] || { echo "  SKIP  bridge plugin missing"; return 0; }

  mkdir -p "$cfgdir" || return 1
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  if ! jq empty "$cfg" 2>/dev/null; then
    echo "  SKIP  $cfg is not valid JSON — fix it by hand, then rerun (refusing to overwrite)"
    return 0
  fi

  tmp="$(mktemp)" || return 1
  mcp="$(_sjh_oc_mcp_json)" || mcp=""
  # `plugin` is a union (the user's own plugins survive); `mcp.sjmcp` is ours to own, and is only
  # touched when we actually have a server to point at.
  jq --argjson plug "$(_sjh_oc_plugin_json)" --arg mcp "$mcp" '
      .plugin = ((.plugin // []) + $plug | unique)
      | if $mcp == "" then . else .mcp = ((.mcp // {}) + {sjmcp: ($mcp | fromjson)}) end
    ' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }

  if cmp -s "$tmp" "$cfg"; then echo "  ok    plugin + mcp registered"; rm -f "$tmp"
  else mv "$tmp" "$cfg"; echo "  wrote $cfg  (plugin$([ -n "$mcp" ] && echo ' + mcp sjmcp'))"; fi

  _sjh_oc_commands "$cfgdir/commands"
}

# --- session hand-off --------------------------------------------------------------------------
# A session is a row in opencode's database, so it cannot simply be dropped into place the way a
# Claude transcript can. `opencode import <file>` is the supported way in: it reads exactly the
# export we archive and re-homes it onto the CURRENT project (it rewrites projectID/directory —
# packages/opencode/src/cli/cmd/import.ts), which is why the import must run in the destination cwd.
# The staged file therefore lands in an inbox rather than in opencode's own storage.
sjh_project_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/scrubjay/inbox/opencode"; }
sjh_import_side() { :; }   # no sidecar records to restore — the export is self-contained

# Install a staged session into opencode for real, so the user is left with ONE command to run
# instead of a copy-pasted two-step.
sjh_install_session() {  # sjh_install_session <staged-file> <cwd> <sid>
  local f="$1" cwd="$2" oc
  oc="${SCRUBJAY_OPENCODE_BIN:-opencode}"
  command -v "$oc" >/dev/null 2>&1 || return 1
  [ -d "$cwd" ] || return 1
  ( cd "$cwd" && "$oc" import "$f" >/dev/null 2>&1 )
}

sjh_resume_cmd() {  # sjh_resume_cmd <sid> <staged-file> [installed]
  if [ "${3:-0}" = "1" ]; then printf 'opencode --session %s' "$1"
  else printf 'opencode import %s   &&   opencode --session %s' "$2" "$1"; fi
}

# Cross-harness carry-over: the session came from a DIFFERENT agent, so there is no native session
# to resume — we hand the conversation over as context instead. See bin/adapters/ROADMAP.md for the
# open issue on translating a session into this harness's own format.
sjh_context_cmd() {  # sjh_context_cmd <primer.md> <src_host> <src_harness>
  printf 'opencode run "Continue the %s session from %s. Read the full transcript at %s first, then pick up where it left off."' \
    "$3" "$2" "$1"
}

# /sjlog publishes the session you are IN, but opencode keeps no transcript file to point at — so
# make one: find the newest session for this directory and export it, exactly as the bridge does on
# idle. The file is named <sid>.json because publish-now.sh reads the session id back off the name.
#
# Note this is rarely needed under opencode: the bridge already publishes after every turn, so
# /sjlog is a "flush now" rather than the "or these turns are lost" it is for Claude.
sjh_find_live_transcript() {  # sjh_find_live_transcript <cwd> [sid]
  local cwd="$1" sid="${2:-}" dir out
  command -v opencode >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$sid" ] || sid="$(opencode session list --format json 2>/dev/null \
         | jq -r --arg d "$cwd" '[ .[] | select(.directory == $d) ] | sort_by(.updated) | last | .id // ""')"
  [ -n "$sid" ] || return 0
  # The basename IS the session id — publish-now.sh reads it back off the path — so the export goes
  # into a directory of its own rather than carrying a disambiguating prefix in its name.
  dir="${TMPDIR:-/tmp}/scrubjay-opencode"
  mkdir -p "$dir" || return 0
  out="$dir/$sid.json"
  opencode export "$sid" > "$out" 2>/dev/null || return 0
  [ -s "$out" ] && jq empty "$out" 2>/dev/null && printf '%s' "$out"
}
