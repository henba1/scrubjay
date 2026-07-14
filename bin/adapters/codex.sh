#!/usr/bin/env bash
# Harness adapter: OpenAI Codex CLI. Source this; do not execute. See bin/adapters/README.md.
#
# Codex is the cheap one where opencode was expensive, and vice versa:
#
#   * Its hooks are Claude-shaped. `~/.codex/hooks.json` takes the same
#     {"hooks": {"<Event>": [{"hooks": [{"type": "command", "command": …}]}]}} structure as Claude's
#     settings.json, and a command hook is handed the same JSON on stdin: session_id, cwd,
#     transcript_path (codex-rs/hooks/schema/generated/*.command.input.schema.json). So scrubjay's
#     SessionStart/SessionEnd hooks run against codex UNCHANGED — no bridge, no shim.
#   * Its transcript is already a .jsonl file on disk: a "rollout" at
#     ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl, one RolloutLine per line
#     ({timestamp, type, payload}) — so there is nothing to export, only a different record schema
#     to read (bin/render-codex.sh).
#
# Two traps, both handled below:
#   1) There is NO SessionEnd — only `Stop`, which fires at the end of every TURN. So a codex
#      session is shipped repeatedly, like opencode's. This costs nothing: the transports are
#      idempotent, and the git backend only commits when content actually changed.
#   2) `transcript_path` is nullable, and the rollout's parent directory is a DATE, not a project.
#      So the slug comes from the session's cwd, and there is a lookup for when the path is absent.

sjh_config_dir() { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }
sjh_present()    { command -v codex >/dev/null 2>&1; }

sjh_transcript_ext() { printf 'jsonl'; }
sjh_session_handle() { printf '%.8s' "$1"; }   # session ids are UUIDs: the first 8 hex

# Codex has no project-dir encoding of its own — rollouts are filed by DATE
# (…/sessions/2026/07/14/rollout-….jsonl), so the parent dir is "14", not a project. Slug the
# session's cwd instead, the same way the other adapters do, so one archive layout —
# <host>/<slug>/<sid>.<ext> — holds every harness.
sjh_slug()         { printf '%s' "$1" | sed 's/[^A-Za-z0-9-]/-/g'; }
sjh_session_slug() { local cwd="$2"; [ -n "$cwd" ] || cwd="$(sjh_session_cwd "$1")"; sjh_slug "$cwd"; }

# The session's cwd is recorded once, in the `session_meta` line that opens every rollout.
sjh_session_cwd() {  # sjh_session_cwd <rollout.jsonl>
  jq -r 'select(.type == "session_meta") | .payload.cwd // empty' "$1" 2>/dev/null | head -1
}

# First real user prompt, one line. A rollout's user messages include codex's own injected context
# (<environment_context>, <user_instructions>, …) — the same problem Claude's <system-reminder>
# blocks pose, and the same cut: drop the ones that open with '<'.
sjh_session_topic() {  # sjh_session_topic <rollout.jsonl>
  jq -r 'select(.type == "response_item") | .payload
         | select(.type == "message" and .role == "user")
         | [ .content[]? | select(.type == "input_text") | .text ] | join(" ")
         | select(type == "string")
         | sub("^\\s+"; "") | sub("\\s+$"; "")
         | select(. != "" and (startswith("<") | not))' "$1" 2>/dev/null \
    | head -1 | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//'
}

sjh_render() { bash "$(sj_app)/bin/render-codex.sh" "$1"; }

# Codex keeps no plans/, task list or file-history tree. What it does keep is the cross-session
# prompt history — same record, same sensitivity, as Claude's.
sjh_extra_artifacts() {  # sjh_extra_artifacts <transcript> <sid> <slug> <cwd>
  local root; root="$(sjh_config_dir)"
  [ -f "$root/history.jsonl" ] && printf '%s\t%s\t\n' "$root/history.jsonl" "history.jsonl"
  return 0
}

# The rollout for a session, when the hook payload's `transcript_path` came through null (it is
# declared nullable). Prefer an exact match on the session id — the rollout filename ends with it,
# and the opening session_meta line carries it — and fall back to the newest rollout recorded for
# this cwd. Never guesses across sessions when a sid is available.
sjh_find_live_transcript() {  # sjh_find_live_transcript <cwd> [sid]
  local cwd="$1" sid="${2:-}" root f
  root="$(sjh_config_dir)/sessions"
  [ -d "$root" ] || return 0
  if [ -n "$sid" ]; then
    f="$(find "$root" -type f -name "rollout-*$sid*.jsonl" 2>/dev/null | head -1)"
    [ -n "$f" ] && { printf '%s' "$f"; return 0; }
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(sjh_session_cwd "$f")" = "$cwd" ]; then printf '%s' "$f"; return 0; fi
  done < <(find "$root" -type f -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
           | sort -rn | head -50 | cut -d' ' -f2-)
}

# --- config ------------------------------------------------------------------------------------
# P1 installs the lifecycle hooks and nothing else. Codex config is TOML, so the settings merge,
# the sjmcp registration ([mcp_servers.sjmcp]) and the slash commands (~/.codex/prompts/) are P3 —
# see bin/adapters/ROADMAP.md. Hooks, mercifully, live in their own JSON file.
#
#   SessionStart -> hooks/sync-session.sh   (pull config + memory, apply)
#   Stop         -> hooks/log-session.sh    (log line, data-repo push, memory push, relay)
#
# `async: true` on Stop so publishing never delays the next turn. SCRUBJAY_HARNESS is set inline:
# the hook scripts read the harness from the environment, and codex does not put it there.
sjh_apply_config() {
  local cfgdir hooks app tmp sync_cmd log_cmd
  cfgdir="$(sjh_config_dir)"; hooks="$cfgdir/hooks.json"; app="$(sj_app)"

  echo "codex: $cfgdir"
  command -v jq >/dev/null 2>&1 || { echo "  SKIP  jq not on PATH"; return 0; }
  mkdir -p "$cfgdir" || return 1
  [ -f "$hooks" ] || echo '{}' > "$hooks"
  if ! jq empty "$hooks" 2>/dev/null; then
    echo "  SKIP  $hooks is not valid JSON — fix it by hand, then rerun (refusing to overwrite)"
    return 0
  fi

  sync_cmd="SCRUBJAY_HARNESS=codex bash \"$app/hooks/sync-session.sh\""
  log_cmd="SCRUBJAY_HARNESS=codex bash \"$app/hooks/log-session.sh\""

  tmp="$(mktemp)" || return 1
  # Drop any previous scrubjay entry before re-adding, so the registration follows the app when the
  # clone moves, and never accumulates duplicates. Other people's hooks are matched on neither
  # script name, so they survive untouched.
  jq --arg sync "$sync_cmd" --arg log "$log_cmd" '
      def strip($needle):
        map(select(((.hooks // []) | map(.command // "") | join(" ") | contains($needle)) | not));
      .hooks = (.hooks // {})
      | .hooks.SessionStart =
          ((.hooks.SessionStart // []) | strip("hooks/sync-session.sh")
           + [{hooks: [{type: "command", command: $sync, timeout: 60}]}])
      | .hooks.Stop =
          ((.hooks.Stop // []) | strip("hooks/log-session.sh")
           + [{hooks: [{type: "command", command: $log, timeout: 120, async: true}]}])
    ' "$hooks" > "$tmp" || { rm -f "$tmp"; return 1; }

  if cmp -s "$tmp" "$hooks"; then echo "  ok    hooks registered (SessionStart, Stop)"; rm -f "$tmp"
  else mv "$tmp" "$hooks"; echo "  wrote $hooks  (SessionStart -> sync, Stop -> publish)"; fi

  echo "  note  sjmcp + /sj* commands not registered for codex yet (TOML config — ROADMAP P3)"
}

# --- session hand-off: NOT WIRED UP (ROADMAP P2) -----------------------------------------------
# `codex resume <id>` resolves a session through codex's own index, not from a path handed to it —
# the `experimental_resume` config key that used to take a file is gone. So dropping a rollout into
# ~/.codex/sessions/ is not enough to make codex see it, and the honest thing is to stage the file
# and say so, rather than print a command that will not find it.
sjh_project_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/scrubjay/inbox/codex"; }
sjh_import_side() { :; }
sjh_resume_cmd()  {  # sjh_resume_cmd <sid> <staged-file>
  printf 'the rollout is staged at %s — but hand-off INTO codex is not wired up yet (it indexes\n      sessions itself, so a file alone is not enough): see bin/adapters/ROADMAP.md, codex P2' "$2"
}
