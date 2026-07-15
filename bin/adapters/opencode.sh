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
#   * shared + per-host settings   (opencode.json, deep-merged under your own keys)
#   * the shared instructions      (opencode.json `instructions` -> <data>/shared/AGENTS.md)
#   * the lifecycle bridge plugin  (opencode.json `plugin`)
#   * the sjmcp archive server     (opencode.json `mcp`)   -> /sjrecall & co. work INSIDE opencode
#   * the /sj* + personal commands (commands/*.md)
#   * agents                       (agent/*.md, translated from claude-md/agents + native ones)
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
#
# Commands come from TWO sources, in precedence order: the app ships the generic /sj* family, and
# any extra dirs passed in (the data repo's personal commands) OVERRIDE on a name clash — the same
# app-then-data precedence link_commands() gives Claude in bin/claude-sync.sh.
_sjh_oc_commands() {
  local dst="$1"; shift
  local app src name n=0 srcdir
  app="$(sj_app)"
  mkdir -p "$dst" || return 1
  for srcdir in "$app/commands" "$@"; do
    [ -d "$srcdir" ] || continue
    for src in "$srcdir"/*.md; do
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
  done
  echo "  gen   $n commands -> $dst/"
}

# --- agents ------------------------------------------------------------------------------------
# scrubjay's agents are authored for Claude (claude-md/agents/*.md). opencode reads the same
# markdown-with-frontmatter shape, so we TRANSLATE rather than copy — verified against opencode
# 1.17.20, which loads agents from <config>/agent/ (singular):
#   * `name:`/`model:` are dropped — opencode takes the name from the filename, and a subagent with
#     no model inherits the invoking agent's, which is the right default (inventing
#     anthropic/claude-sonnet-5 would be wrong for anyone driving opencode via Zen/OpenRouter).
#   * `mode: subagent` is added (Claude agents are all subagents).
#   * Claude's `tools:` is an ALLOWLIST, so it maps onto opencode's `permission` map: allow the
#     mapped keys, DENY every other key opencode knows. Without the denies a restricted agent would
#     silently gain tools it was never granted. No `tools:` line -> no permission block (inherits all).
# Native opencode agents (data repo's opencode/agent/) are symlinked as-is and win on a name clash.
# Generated files are regenerated every sync — edit the source, never the copy.

# Emit the `permission:` block body for a Claude `tools:` allowlist. opencode's recognized tool keys
# (empirically, 1.17.20): bash read grep glob edit write patch list task webfetch websearch
# todowrite todoread skill. Claude folds file mutation into Edit/Write/MultiEdit/NotebookEdit, so
# any of those unlocks opencode's whole edit/write/patch family; TodoWrite unlocks todowrite+todoread.
_sjh_oc_agent_perm() {  # _sjh_oc_agent_perm <claude-tools-csv>
  local t edit=0 bash=0 read=0 grep=0 glob=0 ls=0 task=0 wf=0 ws=0 todo=0 skill=0
  local IFS=', '
  for t in $1; do
    case "$t" in
      Bash) bash=1 ;; Read) read=1 ;; Grep) grep=1 ;; Glob) glob=1 ;; LS) ls=1 ;;
      Edit|Write|MultiEdit|NotebookEdit) edit=1 ;;
      Task) task=1 ;; WebFetch) wf=1 ;; WebSearch) ws=1 ;; TodoWrite) todo=1 ;; Skill) skill=1 ;;
      *) : ;;   # unknown Claude tool — denied by omission
    esac
  done
  local pair k v
  for pair in bash:$bash read:$read grep:$grep glob:$glob edit:$edit write:$edit patch:$edit \
              list:$ls task:$task webfetch:$wf websearch:$ws todowrite:$todo todoread:$todo skill:$skill; do
    k="${pair%:*}"; v="${pair#*:}"
    if [ "$v" = 1 ]; then echo "  $k: allow"; else echo "  $k: deny"; fi
  done
}

# Translate one Claude agent file into opencode's dialect.
_sjh_oc_translate_agent() {  # _sjh_oc_translate_agent <src.md> <dst.md>
  local src="$1" dst="$2" desc tools
  desc="$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$src")"
  tools="$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^tools:/{sub(/^tools:[[:space:]]*/,""); print; exit}' "$src")"
  {
    echo "---"
    [ -n "$desc" ] && echo "description: $desc"
    echo "mode: subagent"
    if [ -n "$tools" ]; then
      echo "permission:"
      _sjh_oc_agent_perm "$tools"
    fi
    echo "---"
    # body: everything after the closing (second) `---`
    awk 'n>=2{print} /^---[[:space:]]*$/{n++}' "$src"
  } > "$dst"
}

_sjh_oc_agents() {  # _sjh_oc_agents <dst-agent-dir>
  local dst="$1" data src name n=0
  data="$(sj_data 2>/dev/null)" || return 0
  [ -n "$data" ] || return 0
  mkdir -p "$dst" || return 1
  if [ -d "$data/claude-md/agents" ]; then
    for src in "$data"/claude-md/agents/*.md; do
      [ -f "$src" ] || continue
      _sjh_oc_translate_agent "$src" "$dst/$(basename "$src")" && n=$((n + 1))
    done
  fi
  if [ -d "$data/opencode/agent" ]; then      # native opencode agents win on a name clash
    for src in "$data"/opencode/agent/*.md; do
      [ -f "$src" ] || continue
      ln -sf "$src" "$dst/$(basename "$src")" && n=$((n + 1))
    done
  fi
  echo "  gen   $n agents -> $dst/"
}

# A data-repo config layer (base or host overlay): its JSON object, or {} when absent. An
# unparseable layer is skipped with a warning rather than aborting the whole apply.
_sjh_oc_layer() {  # _sjh_oc_layer <file>
  local f="$1"
  [ -f "$f" ] || { printf '{}'; return 0; }
  if jq empty "$f" 2>/dev/null; then cat "$f"
  else echo "  WARN  ignoring unparseable $f" >&2; printf '{}'; fi
}

# opencode combines an `instructions` array of file paths with AGENTS.md. Point it at the shared
# instructions by ABSOLUTE path so a `git pull` of the data repo updates it live — only when the
# file actually exists, so we never register a dangling path.
_sjh_oc_instructions_json() {  # _sjh_oc_instructions_json <data>
  local data="$1" f="$1/shared/AGENTS.md"
  if [ -n "$data" ] && [ -f "$f" ]; then jq -n --arg p "$f" '[$p]'; else printf '[]'; fi
}

sjh_apply_config() {
  local cfgdir cfg tmp mcp data basejson hostjson instr
  cfgdir="$(sjh_config_dir)"
  cfg="$cfgdir/opencode.json"
  data="$(sj_data 2>/dev/null)" || data=""

  echo "opencode: $cfgdir"
  command -v jq >/dev/null 2>&1 || { echo "  SKIP  jq not on PATH"; return 0; }
  [ -f "$(sj_app)/hooks/opencode/scrubjay.js" ] || { echo "  SKIP  bridge plugin missing"; return 0; }

  mkdir -p "$cfgdir" || return 1
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  if ! jq empty "$cfg" 2>/dev/null; then
    echo "  SKIP  $cfg is not valid JSON — fix it by hand, then rerun (refusing to overwrite)"
    return 0
  fi

  # Data-repo layers: shared defaults + this host's overlay. Same model as Claude's
  # settings.base.json + host overlay.
  basejson="$(_sjh_oc_layer "$data/opencode/opencode.base.json")"
  hostjson="$(_sjh_oc_layer "$data/hosts/$(sj_host)/opencode/opencode.json")"
  instr="$(_sjh_oc_instructions_json "$data")"

  tmp="$(mktemp)" || return 1
  mcp="$(_sjh_oc_mcp_json)" || mcp=""
  # The merge, keyed to keep exactly what each side owns:
  #   $user * ($base * $host)   base/host win where they define a key; every key you set that the
  #                             data repo doesn't mention (theme, model, keybinds, your own plugins/
  #                             MCP) survives untouched. NOT defaults-only: after the first sync the
  #                             data-repo keys are in your file, so a later change in the data repo
  #                             would never take effect again — this keeps sync a sync.
  #   plugin / instructions     arrays WE contribute to, unioned (the array-union idiom claude-sync
  #                             uses for permissions.allow/deny) so the user's own entries survive.
  #   mcp.sjmcp                 ours to own, only when we actually have a server to point at.
  jq -n \
      --argjson user "$(cat "$cfg")" \
      --argjson base "$basejson" \
      --argjson host "$hostjson" \
      --argjson plug "$(_sjh_oc_plugin_json)" \
      --argjson instr "$instr" \
      --arg     mcp  "$mcp" '
      ($user * ($base * $host))
      | .plugin = ((($user.plugin // []) + ($base.plugin // []) + ($host.plugin // []) + $plug) | unique)
      | .instructions = ((($user.instructions // []) + ($base.instructions // []) + ($host.instructions // []) + $instr) | unique)
      | if (.instructions | length) == 0 then del(.instructions) else . end
      | if $mcp == "" then . else .mcp = ((.mcp // {}) + {sjmcp: ($mcp | fromjson)}) end
    ' > "$tmp" || { rm -f "$tmp"; return 1; }

  if cmp -s "$tmp" "$cfg"; then echo "  ok    settings + plugin + mcp"; rm -f "$tmp"
  else mv "$tmp" "$cfg"; echo "  wrote $cfg  (settings + plugin$([ -n "$mcp" ] && echo ' + mcp sjmcp'))"; fi

  _sjh_oc_commands "$cfgdir/commands" "$data/claude-md/commands"
  _sjh_oc_agents   "$cfgdir/agent"
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
