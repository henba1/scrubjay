#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Shared helpers for the scrubjay app. Source this; do not execute.
# The app (logic) is this repo; personal content lives in a separate data repo, and
# transcripts in a separate relay repo. Pointers come from ~/.config/scrubjay/config.

sj_load_config() {
  [ -f "$HOME/.config/scrubjay/config" ] && . "$HOME/.config/scrubjay/config"
  : "${SCRUBJAY_TRANSCRIPT_BACKEND:=git}"
}

# ---- portability: GNU coreutils vs BSD/macOS ---------------------------------------------------
# scrubjay grew up on Linux, so GNU flags leaked in. Most of them fail *quietly* off GNU — a
# `2>/dev/null || echo 0` fallback turns "this tool doesn't exist here" into a plausible-looking
# wrong answer. These shims keep every call site honest on both userlands. Anything added below
# must degrade loudly or fail closed, never to a made-up value.

sj_has() { command -v "$1" >/dev/null 2>&1; }

# Canonical absolute path, existing paths only (GNU `realpath -e` semantics), with every symlink
# component resolved.
#
# SECURITY: two callers (sj_archive_copy below, confine() in bin/sjmcp-serve.sh) use this to prove
# an archive entry does not escape its root, and the archive is written by *other* hosts over the
# relay — so a symlink can sit inside it that never appears in the path we were handed. A shim that
# only resolved the parent directory would be a confinement bypass. If nothing here can do full
# resolution we return non-zero and let the caller refuse; we never guess.
sj_realpath() {  # sj_realpath <path>
  local p="$1" r
  [ -e "$p" ] || return 1
  # GNU realpath. BSD/macOS realpath has no -e but fails on a missing path anyway, so try both.
  if sj_has realpath; then
    r="$(realpath -e "$p" 2>/dev/null)" || r="$(realpath "$p" 2>/dev/null)" || r=""
    [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  fi
  # readlink -f: GNU everywhere, macOS only since Ventura. Absent on older BSDs.
  if r="$(readlink -f "$p" 2>/dev/null)" && [ -n "$r" ]; then printf '%s' "$r"; return 0; fi
  if sj_has python3; then
    r="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null)" \
      && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  fi
  return 1
}

# Epoch mtime / size in bytes of a file. GNU stat is -c, BSD stat is -f. Both return non-zero
# rather than a fabricated 0, so callers can tell "empty file" from "couldn't ask".
sj_mtime() { stat -c%Y "$1" 2>/dev/null || stat -f%m "$1" 2>/dev/null; }
sj_size()  { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null; }

# Epoch seconds -> YYYY-MM-DD. GNU takes -d @N, BSD takes -r N.
sj_epoch_ymd() {  # sj_epoch_ymd <epoch>
  date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null
}

# Epoch seconds -> "YYYY-MM-DD HH:MM" in LOCAL time — the catalogue row's timestamp format.
# Local, not UTC, because a row written live uses a bare `date`, and a catalogue whose rows are
# in two different timezones sorts wrong. That is also why a reconciled row dates itself from the
# transcript's mtime rather than the ISO-8601 timestamps *inside* it: those are UTC, and shifting
# them to local needs `date -d` (GNU) or `date -j -f` (BSD) — the exact split these shims exist to
# avoid. mtime is already local-clock-comparable, needs no jq pass, and for a session that died
# without warning it is precisely the fact we want: when it last wrote anything.
sj_epoch_stamp() {  # sj_epoch_stamp <epoch>
  date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null
}

# In-place sed. GNU treats -i's argument as optional; BSD requires an explicit backup suffix, so
# `sed -i -e …` on macOS silently eats "-e" as the suffix. Passing '' explicitly is the only form
# both accept — via two different argument shapes.
sj_sed_i() {  # sj_sed_i <sed-args…> <file>
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

# `timeout <secs> <cmd…>`, degrading to an unguarded run. GNU coreutils only: macOS has it as
# `gtimeout` if coreutils is installed, and otherwise not at all — where the bare call would fail
# with "command not found" and the git push it guards would simply never happen. Losing the timeout
# is a far smaller harm than losing the command, so the last resort runs it unguarded.
sj_timeout() {  # sj_timeout <secs> <cmd> [args…]
  local secs="$1"; shift
  if   sj_has timeout;  then timeout  "$secs" "$@"
  elif sj_has gtimeout; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# Files under <dir> matching <name-glob>, newest first, one path per line. Replaces
# `find -printf '%T@ %p\n' | sort -rn` — -printf is a GNU extension that BSD find lacks entirely.
sj_ls_by_mtime() {  # sj_ls_by_mtime <dir> <name-glob> [maxdepth]
  local dir="$1" glob="$2" depth="${3:-}" f
  [ -d "$dir" ] || return 0
  { if [ -n "$depth" ]; then find "$dir" -maxdepth "$depth" -type f -name "$glob" 2>/dev/null
    else                     find "$dir" -type f -name "$glob" 2>/dev/null; fi
  } | while IFS= read -r f; do printf '%s\t%s\n' "$(sj_mtime "$f")" "$f"; done \
    | sort -rn | cut -f2-
}

# Absolute path of the app repo (this file lives in <app>/bin/).
sj_app() { (cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

# Display-only: collapse a leading $HOME back to ~ so status/prompt output printed to the
# terminal (and anything copied from it — scrollback, screenshots, pasted bug reports) doesn't
# carry the OS username. Never use the result for anything but printing — it is not a real path.
# NOTE: the replacement side of ${../../..} is itself subject to tilde expansion, so a bare ~
# here would re-expand right back to $HOME — it must stay escaped.
sj_pretty_path() { printf '%s' "${1/#$HOME/\~}"; }

# Version of the app. VERSION is the release marker; on the supported install (a git clone) the
# precise commit is appended, so a bug report pins the exact code that ran.
sj_version() {
  local app v
  app="$(sj_app)"
  v="$(cat "$app/VERSION" 2>/dev/null)" || v=""
  [ -n "$v" ] || v="unknown"
  if sj_is_clone; then
    printf '%s (%s)' "$v" "$(git -C "$app" describe --tags --always --dirty 2>/dev/null || echo 'no tag')"
  else
    printf '%s (not a git clone — self-update disabled)' "$v"
  fi
}

# The app updates ITSELF via `git pull` in hooks/sync-session.sh, and bin/onboard.sh reads the
# clone to bootstrap. A source tarball/zip has no .git, so the pull silently no-ops and the install
# rots unnoticed. Callers use this to say so out loud rather than fail quietly.
sj_is_clone() { [ -d "$(sj_app)/.git" ] && command -v git >/dev/null 2>&1; }

# Stable host name — NOT `hostname -s` (transient on HPC login nodes).
sj_host() {
  if   [ -n "${CLAUDE_HOST:-}" ];             then printf '%s' "$CLAUDE_HOST"
  elif [ -f "$HOME/.config/scrubjay/host" ]; then cat "$HOME/.config/scrubjay/host"
  else                                             hostname -s; fi
}

# Path to the data repo (required).
sj_data() {
  sj_load_config
  if [ -z "${SCRUBJAY_DATA:-}" ]; then
    echo "scrubjay: SCRUBJAY_DATA not set — see ~/.config/scrubjay/config" >&2
    return 1
  fi
  printf '%s' "$SCRUBJAY_DATA"
}

# Path to the transcripts relay repo (optional; empty if transcript sync is off).
sj_chats() { sj_load_config; printf '%s' "${SCRUBJAY_CHATS:-}"; }

# Cross-machine memory rides its OWN git repo, self-hosted on the NAS over WireGuard — so the
# sensitive paths in auto-memory sync between machines (merge + history) without ever touching a
# third party like GitHub (which still holds only the non-sensitive config).
#   sj_memory         local working clone (Claude's per-project memory dirs symlink into it)
#   sj_memory_remote  the bare repo: a local path on the NAS box, ssh://…over-WG on clients.
#                     Empty -> memory git sync is OFF (the dir is then just machine-local).
sj_memory()        { sj_load_config; printf '%s' "${SCRUBJAY_MEMORY:-$HOME/.scrubjay/scrubjay-memory}"; }
sj_memory_remote() { sj_load_config; printf '%s' "${SCRUBJAY_MEMORY_REMOTE:-}"; }

# --- the harness seam (bin/adapters/<harness>.sh) ---------------------------------------------
# scrubjay's other pluggable half. The transport answers "where do a session's records go?"; an
# adapter answers "which coding agent produced them, and where does IT keep config, transcripts and
# resumable sessions?". Everything between the two — the archive layout, the logs catalogue, the
# memory repo, the readable layer, the sjmcp server — is harness-agnostic. See bin/adapters/README.md.
#
#   sj_harnesses   every harness this machine syncs config into (bin/sync-config.sh walks these)
#   sj_harness     the ONE harness a given hook invocation belongs to — set by whatever fired it
sj_harnesses() { sj_load_config; printf '%s' "${SCRUBJAY_HARNESSES:-claude}"; }
sj_harness()   { sj_load_config; printf '%s' "${SCRUBJAY_HARNESS:-claude}"; }

# Source one adapter into the caller's shell. The sjh_* functions share a namespace, so a caller
# that walks SEVERAL harnesses must do each in a subshell.
sj_load_adapter() {  # sj_load_adapter [harness]
  local h="${1:-}" f
  [ -n "$h" ] || h="$(sj_harness)"
  f="$(sj_app)/bin/adapters/$h.sh"
  [ -f "$f" ] || { echo "scrubjay: unknown harness '$h' (no $f)" >&2; return 1; }
  # shellcheck source=/dev/null  # harness chosen at runtime; see bin/adapters/<harness>.sh
  . "$f"
}

# Every adapter that EXISTS (not just the ones this machine syncs): an archived session can come
# from a harness this host has never run.
sj_known_harnesses() {
  local f
  for f in "$(sj_app)"/bin/adapters/*.sh; do
    [ -f "$f" ] && basename "$f" .sh
  done
}

# Call one adapter's function while a DIFFERENT adapter is loaded in the caller's shell. The sjh_*
# namespace is shared, so the only safe way to touch two harnesses at once — which a cross-harness
# hand-off must — is a subshell per call.
sj_adapter_call() {  # sj_adapter_call <harness> <sjh_fn> [args...]
  local h="$1"; shift
  ( sj_load_adapter "$h" >/dev/null 2>&1 || exit 1; "$@" )
}

# Which harness PRODUCED this session file? The archive is deliberately harness-neutral — one
# <host>/<slug>/<sid>.<ext> layout for every agent — so a session carries no label, and a hand-off
# has to work it out from the records themselves. Each adapter recognizes its own format
# (sjh_detect), which also means the whole existing back-catalogue is covered without a migration.
# Prints the harness name; fails (1) if nothing claims the file.
sj_detect_harness() {  # sj_detect_harness <transcript>
  local f="$1" h
  [ -s "$f" ] || return 1
  for h in $(sj_known_harnesses); do
    if sj_adapter_call "$h" sjh_detect "$f" 2>/dev/null; then printf '%s' "$h"; return 0; fi
  done
  return 1
}

# The session's first real user prompt, as one line of plain text ("" if there isn't one).
# Reads the Claude Code / JSONL record shape; a harness that stores sessions differently supplies
# its own extractor as sjh_session_topic (bin/adapters/<harness>.sh).
#
# This is the ONLY topic an ordinary session ever gets: SessionEnd fires with no model in the loop,
# so the model-authored essence exists only on the /sjlog path. Everything it fails to read lands
# in the catalogue as `(no text)`. So it is worth being careful about three things.
#
# 1. `.message.content` is a string on some records and an ARRAY of content blocks on others —
#    which is the common shape for a typed prompt. Reading only the string form silently drops
#    most sessions, so normalize the array to its joined text blocks first (tool_result / image
#    blocks carry no prompt and are skipped).
#
# 2. `isMeta` is Claude Code's own marker for a record the user did not type: the `Caveat:`
#    preamble, hook output, a skill's injected header, and — the one that mattered most — the
#    expanded *body* of a slash command, which arrives as a user record immediately after the
#    invocation. Reading that body made `/sjrecall foo` log its own command markdown ("The user
#    wants to find a past conversation…") as the session's topic: a WRONG topic, which is worse
#    than a blank one because nothing about it looks broken. Keying on the flag is exact where
#    guessing from adjacency was not. `isSidechain` marks a subagent's turns — never the session's
#    own topic. Both are read defensively (`!= true`), so a record lacking the field still counts.
#
# 3. The injected `<...>` wrappers are *stripped* rather than used to reject the whole record.
#    A typed prompt routinely arrives with a `<system-reminder>` block glued to it, and rejecting
#    on a leading `<` threw the prompt away with the wrapper. Anything still opening with `<` after
#    the strip is an injected block we don't know, and is skipped as before.
#
# When there is no prose at all the topic falls back to the slash command the user actually ran
# (`/clear`, `/sjresume 065f6e66`). That is what most topic-less sessions in the catalogue turn out
# to be, and naming the command is honest: it says the session happened and what it was.
# Prose wins over the command, so a session that runs `/clear` and then does real work is still
# titled by the work.
sj_session_topic() {  # sj_session_topic <transcript.jsonl>
  jq -rs '
    def clean:
        gsub("(?s)<local-command-caveat>.*?</local-command-caveat>"; "")
      | gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
      | gsub("(?s)<environment_context>.*?</environment_context>"; "")
      | gsub("(?s)<user-prompt-submit-hook>.*?</user-prompt-submit-hook>"; "")
      | sub("^\\s+"; "") | sub("\\s+$"; "");
    def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
    def cmd:
      if test("<command-name>") then
        ((capture("<command-name>(?<v>[^<]*)</command-name>").v | trim) as $n
         | (if test("<command-args>")
            then (capture("(?s)<command-args>(?<v>.*?)</command-args>").v | trim) else "" end) as $a
         | if $n == "" then "" elif $a == "" then $n else $n + " " + $a end)
      else "" end;
    [ .[]
      | select(.type == "user" and .isSidechain != true and .isMeta != true)
      | .message.content
      | if type == "array" then [ .[] | select(.type == "text") | .text ] | join("\n") else . end
      | select(type == "string") ]
    | ( [ .[] | select(test("<command-name>") | not) | clean
          | select(. != ""
                   and ((startswith("<") or startswith("Caveat")
                         or startswith("[Request interrupted")) | not)) ] | first ) as $prose
    | ( [ .[] | cmd | select(. != "") ] | first ) as $cmd
    | $prose // $cmd // ""' \
    "$1" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//'
}

# The date a session STARTED, as YYYY-MM-DD, read from the transcript's own records.
#
# This is what the readable filename is dated by, and it must be a pure function of the session:
# the readable file is (re)written on EVERY publish — /sjlog can run several times, then session end
# runs — and each publish recomputes the name. A name derived from anything mutable produces a
# second file instead of overwriting the first, and since nothing prunes the readable tree (the
# rrsync receiver's key is write-only by design) the older, shorter copy survives as a duplicate of
# the same session. The readers then disagree: /sjrecall scores both and can rank the stale one
# higher, and resolve_ref returns whichever it iterates onto first.
#
# File mtime was that mutable thing, in two ways. A session /sjlog'd either side of midnight
# changed dates mid-life; and a transcript's mtime does not survive being copied — the `local`
# transport ships with `cp -f` (no -p), so bin/backfill-readable.sh, reading the archived copy,
# would date a session from when it was *shipped* and mint a second name for it.
#
# Reading only the head keeps this cheap on a transcript that can be tens of MB, and each line is
# parsed on its own (`-R … fromjson?`) so one odd or truncated line is skipped rather than failing
# the read. Falls back to mtime, then to today: a date is always produced, never an empty path
# component.
sj_transcript_date() {  # sj_transcript_date <transcript>
  local src="$1" t="" d mt
  if command -v jq >/dev/null 2>&1; then
    # Claude and codex are JSONL and carry an ISO-8601 `timestamp` per record — but not necessarily
    # on the FIRST line (Claude opens with a `mode`/`sessionId` record), hence the small window.
    # Bounded in BYTES as well as lines: opencode's export is one enormous single line, and a
    # line-count limit alone would pull the whole document through jq only to find no `.timestamp`.
    # A truncated tail just fails `fromjson?`, which this already tolerates.
    t="$(head -c 262144 "$src" 2>/dev/null | head -100 \
          | jq -rR 'fromjson? | .timestamp? // empty' 2>/dev/null | head -1)"
    # opencode's export is a single JSON *document*, so the line-wise read above finds nothing. Its
    # start time is one field — in epoch MILLISECONDS. This matters most for opencode: its transcript
    # is exported fresh into a temp file on every publish, so its mtime is always "now".
    [ -n "$t" ] || t="$(jq -r '.info.time.created? // empty' "$src" 2>/dev/null)"
  fi
  case "$t" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      # ISO-8601: slice the date off the string rather than parsing it. `date -d` is GNU-only and
      # `date -r` means different things on GNU (epoch) and BSD (file mtime) — staying in string
      # space sidesteps the split the shims at the top of this file exist for.
      printf '%.10s' "$t"; return 0 ;;
    ''|*[!0-9]*) ;;                                  # not a date and not a number — fall through
    *)
      [ "${#t}" -gt 11 ] && t="${t%???}"             # milliseconds once it outgrows 11 digits
      d="$(sj_epoch_ymd "$t")" && [ -n "$d" ] && { printf '%s' "$d"; return 0; } ;;
  esac
  mt="$(sj_mtime "$src")" && [ -n "$mt" ] && d="$(sj_epoch_ymd "$mt")" && [ -n "$d" ] \
    && { printf '%s' "$d"; return 0; }
  date +%F
}

# Free text -> a filename-safe slug: lowercase [a-z0-9-], no leading/trailing dashes, truncated to
# <maxlen> (default 40) without leaving a dangling dash. Every archived artifact's name goes through
# here, which is what lets `mcp/sjmcp_server.py` parse metadata straight off a filename: the slug can
# never contain the `__` that separates a topic from its session handle.
sj_slugify() {  # sj_slugify <text> [maxlen]
  printf '%s' "$1" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-" \
    | sed -E "s/^-+//; s/-+$//" | cut -c1-"${2:-40}" | sed -E "s/-+$//"
}

# First free path of the form <dir>/<stem>.<ext>, adding a -2, -3, … suffix on a clash. Callers use
# it to keep same-day, same-topic artifacts from overwriting each other.
sj_unique_path() {  # sj_unique_path <dir> <stem> <ext>
  local dir="$1" stem="$2" ext="$3" n=2
  if [ ! -e "$dir/$stem.$ext" ]; then printf '%s/%s.%s' "$dir" "$stem" "$ext"; return; fi
  while [ -e "$dir/$stem-$n.$ext" ]; do n=$((n + 1)); done
  printf '%s/%s-%s.%s' "$dir" "$stem" "$n" "$ext"
}

# The key a project's cross-machine content (memory, notes) is filed under in the memory repo:
# <mem>/<project_key>/. It MUST agree with what bin/claude-sync.sh links, which is the basename of
# Claude Code's own ~/.claude/projects/<slug>/ dir — so ask the adapter, whose sjh_project_dir finds
# that dir by *reading* local transcripts rather than re-encoding the path (Claude's slug encoding
# is lossy, and a symlinked home makes the naive encoding wrong outright).
#
# The fallback matters as much as the happy path: on a host with no Claude Code at all, an opencode
# or codex session must still land in the SAME directory as a Claude session for the same cwd, or
# the two harnesses would file the same project under two names and /sjrecall would only ever see
# half of it. Slugging the resolved cwd is exactly what sjh_project_dir itself falls back to.
sj_project_key() {  # sj_project_key [cwd]
  local cwd="${1:-$PWD}" d real
  if d="$(sj_adapter_call claude sjh_project_dir "$cwd" 2>/dev/null)" && [ -n "$d" ]; then
    basename "$d"; return
  fi
  real="$(sj_realpath "$cwd" || printf '%s' "$cwd")"
  printf '%s' "$real" | sed 's/[^A-Za-z0-9-]/-/g'
}

# Human-readable relpath for a transcript, under the per-host `readable/` tree:
#   <project>/<date>_<topic>__<sid8>   (project = basename of the session cwd; topic = first
#   real user prompt, slugified).
#
# <cwd> and <topic> are optional: a caller that has a harness adapter loaded passes what the
# adapter extracted (transcripts are not all JSONL). Omitted, they are read from the file itself in
# the Claude/JSONL shape — which is what makes this work for backfill, where there is no session.
sj_readable_relpath() {  # sj_readable_relpath <transcript> <session_id> [cwd] [topic]
  local src="$1" sid="$2" cwd="${3:-}" topic="${4:-}" project d
  if ! command -v jq >/dev/null 2>&1; then printf 'misc/%s' "${sid:0:8}"; return; fi
  [ -n "$cwd" ] || cwd="$(jq -rs '[ .[] | select(.cwd!=null) | .cwd ][0] // ""' "$src" 2>/dev/null)"
  project="$(basename "${cwd:-misc}")"; [ -n "$project" ] && [ "$project" != "/" ] || project="misc"
  [ -n "$topic" ] || topic="$(sj_session_topic "$src")"
  topic="$(sj_slugify "$topic" 40)"
  [ -n "$topic" ] || topic="session"
  d="$(sj_transcript_date "$src")"
  printf '%s/%s_%s__%s' "$project" "$d" "$topic" "$(sj_session_handle "$sid")"
}

# The 8-character handle a session is known by: what the readable filename ends with, what /sjrecall
# shows, and what you hand to /sjresume. The first 8 characters of the id, unless the harness gives
# something better — opencode ids are `ses_<base62>`, where the first 8 would be mostly the prefix.
# Adapter-aware but not adapter-dependent: backfill has no adapter loaded and still gets a handle.
sj_session_handle() {  # sj_session_handle <session_id>
  if declare -F sjh_session_handle >/dev/null 2>&1; then sjh_session_handle "$1"
  else printf '%.8s' "$1"; fi
}

# Give plan files meaningful, date-prefixed names *in place*, so the relay tree (and the local
# plans/ dir) is browsable like readable/ instead of Claude Code's three-random-word names:
#   <date>_<topic>.md   (date = file mtime; topic = the plan's first markdown heading, slugified,
#   with a leading "Plan:"/"Plan -" stripped). Idempotent: files already named <YYYY-MM-DD>_… are
#   left untouched, so it can run on every ship. On a name clash with a *different* file a -N suffix
#   is added. Best-effort and silent — it must never fail the caller (the ship).
sj_normalize_plans() {  # sj_normalize_plans <plans_dir>
  local dir="$1" f base topic d target
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*) continue ;; esac
    topic="$(grep -m1 -E '^#+[[:space:]]+' "$f" 2>/dev/null \
              | sed -E 's/^#+[[:space:]]+//; s/^[Pp]lan[[:space:]]*[:-][[:space:]]*//')"
    topic="$(sj_slugify "$topic" 50)"
    [ -n "$topic" ] || topic="${base%.md}"
    d="$(date -r "$f" +%F 2>/dev/null || date +%F)"
    target="$dir/${d}_${topic}.md"
    [ ! -e "$target" ] || [ "$target" = "$f" ] || target="$(sj_unique_path "$dir" "${d}_${topic}" md)"
    [ "$target" = "$f" ] || mv -- "$f" "$target" 2>/dev/null || true
  done
}

# Machine-local breadcrumb of the last transcript-relay outcome. It lives beside the pointer
# files (NOT in any synced repo) so a *silent* ship failure — e.g. an unauthorized/absent relay
# key on the receiver — surfaces at the next SessionStart instead of going unnoticed for days.
# Written by bin/ship-transcript.sh after the primary transcript push; read by hooks/sync-session.sh.
sj_ship_status_file() { printf '%s' "$HOME/.config/scrubjay/last-ship"; }
sj_record_ship() {  # sj_record_ship <ok|fail> <session_id> <backend> [rc]
  local result="$1" sid="$2" backend="$3" rc="${4:-0}" f
  f="$(sj_ship_status_file)"; mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf 'result=%s ts=%s host=%s backend=%s sid=%s rc=%s\n' \
    "$result" "$(date +%FT%T)" "$(sj_host)" "$backend" "${sid:0:8}" "$rc" > "$f" 2>/dev/null || true
}

# Same idea for cross-machine memory. memory-sync.sh warns on a failed push, but both its callers
# are hooks that redirect stderr to /dev/null (they must never write to a session's stream), so
# that warning reached nobody — a stale remote silently stranded weeks of memory on one machine.
# Written by bin/memory-sync.sh; read by hooks/sync-session.sh.
sj_memory_status_file() { printf '%s' "$HOME/.config/scrubjay/last-memory-sync"; }

# ONE LINE PER MODE, and that is the whole point. A session pulls at the start and pushes at the
# end, so a single-line breadcrumb meant the push always had the last word — and the push path
# legitimately short-circuits when there is nothing to publish, WITHOUT contacting the remote. A
# machine that could not reach its remote at all therefore ended every session reporting `ok`,
# overwriting the pull's `fail`. Observed on a host that had been cut off for weeks.
#
#   result=ok    the operation reached the remote and did what it says
#   result=fail  it tried and could not — the thing worth surfacing
#   result=skip  there was nothing to do, so the remote was never contacted. NOT a success claim:
#                it must never clear or mask a fail recorded by the other mode.
sj_record_memory_sync() {  # sj_record_memory_sync <ok|fail|skip> <pull|push> <remote> [detail]
  local result="$1" mode="$2" remote="$3" detail="${4:-}" f tmp
  f="$(sj_memory_status_file)"; mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  tmp="$f.tmp.$$"
  # The group's exit status is the printf's, not the grep's — see sj_clear_pending for why that
  # distinction matters when grep legitimately matches nothing.
  { [ -f "$f" ] && grep -v "^mode=$mode " "$f"
    printf 'mode=%s result=%s ts=%s host=%s remote=%s%s\n' \
      "$mode" "$result" "$(date +%FT%T)" "$(sj_host)" "$remote" "${detail:+ detail=$detail}"
  } > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# --- pending receiver authorization -----------------------------------------------------------
# On the peer-to-peer backends a new machine CANNOT authorize itself: onboarding prints an
# authorized_keys line that a human with root on the receiver must paste. That is deliberate. The
# consequence is that a freshly onboarded host is *expected* to fail every sync until that happens
# — so "not yet authorized" is a normal, resumable state, not an error, and it needs to be recorded
# rather than inferred. Without this the host looks configured, silently syncs nothing, and the
# user has to remember to re-run the publish by hand afterwards (which is how a host sat stranded).
#
# One line per waiting subsystem, TSV: <subsystem> <probe-kind> <probe-target>
#   probe-kind  ssh -> reachable when ssh does NOT exit 255 (the relay key's forced command
#                      refuses every command by design, so only ssh's own 255 means "no")
#               git -> reachable when `git ls-remote` succeeds
sj_pending_file() { printf '%s' "$HOME/.config/scrubjay/pending-authorization"; }

sj_record_pending() {  # sj_record_pending <subsystem> <ssh|git> <target>
  local sub="$1" kind="$2" tgt="$3" f tmp
  f="$(sj_pending_file)"; mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  tmp="$f.tmp.$$"
  { [ -f "$f" ] && grep -v "^$sub	" "$f"; printf '%s\t%s\t%s\n' "$sub" "$kind" "$tgt"; } \
    > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

sj_clear_pending() {  # sj_clear_pending <subsystem>
  local sub="$1" f tmp; f="$(sj_pending_file)"; [ -f "$f" ] || return 0
  tmp="$f.tmp.$$"
  # NB: `grep -v` exits 1 when it prints nothing, which is exactly the case where the LAST pending
  # entry is being cleared — branching on its exit code would leave the file behind forever and
  # keep reporting a wait that is over. Judge by the output, not the status.
  grep -v "^$sub	" "$f" > "$tmp" 2>/dev/null || true
  if [ -s "$tmp" ]; then mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else rm -f "$tmp" "$f" 2>/dev/null; fi          # nothing left waiting: drop the file entirely
  return 0
}

sj_pending_authorized() {  # sj_pending_authorized <ssh|git> <target>  -> 0 when it now works
  local kind="$1" tgt="$2"
  case "$kind" in
    ssh) sj_timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$tgt" true >/dev/null 2>&1
         [ "$?" != 255 ] ;;
    git) GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=8' \
           sj_timeout 20 git ls-remote "$tgt" HEAD >/dev/null 2>&1 ;;
    *)   return 1 ;;
  esac
}

# --- session hand-off (bin/sj-resume.sh) ------------------------------------------------------
# Where a session lives locally, and how a harness encodes a project into a directory name, are
# harness-specific — they moved to bin/adapters/<harness>.sh (sjh_project_dir / sjh_slug).

# --- the catalogue: one writer, one reader ------------------------------------------------------

# Append this machine's catalogue row for ONE session. The sole writer of the log-line format —
# hooks/log-session.sh writes it when a session ends, bin/sj-reconcile.sh writes it for a session
# that ended without ever reaching the hook. It lives here, next to sj_log_catalogue (the reader),
# because the line IS the interface: sjmcp's _LOG regex and sj_log_catalogue's pipe-split both
# parse it, and tests/test_log.sh pins its shape. A second place that formatted it would drift.
#
# Returns 0 when a row was written, 1 when there was nothing to write (already catalogued, or the
# session recorded nothing) — callers count on that to decide whether a push is even needed.
#
# <ts> and <topic> may be empty: ts defaults to now, topic to the first real user prompt. Both are
# parameters rather than reads of the ambient environment so the function stays testable — the
# `/sjlog` essence (SCRUBJAY_TOPIC) is passed in by the hook, not picked up here.
sj_log_row() {  # sj_log_row <log> <sid> <cwd> <transcript> <harness> <host> <ts> <topic>
  local log="$1" sid="$2" cwd="$3" tpath="$4" harness="$5" host="$6" ts="$7" topic="${8:-}"
  local model="" turns="" size=0

  # A session with no transcript produced no records at all: nothing is shipped for it and nothing
  # is rendered, so a row would advertise an archive entry that does not exist. This is not
  # hypothetical — a session ended without a single user turn (open the harness and /clear, or quit
  # straight away) still fires SessionEnd, naming a transcript_path that was never written. `-s`
  # covers both the missing file and the empty one.
  [ -s "${tpath:-}" ] || return 1
  [ -n "$sid" ] || return 1
  grep -q "session=$sid" "$log" 2>/dev/null && return 1   # write-once per session

  [ -n "$ts" ] || ts="$(date '+%Y-%m-%d %H:%M')"
  # Topic: prefer the caller's (a model-authored essence from /sjlog); else the first real user
  # prompt. The adapter knows how to read its own transcript format; sj_session_topic is the
  # Claude/JSONL shape and the fallback for a caller with no adapter loaded (backfill).
  if [ -z "$topic" ]; then
    if declare -F sjh_session_topic >/dev/null 2>&1; then topic="$(sjh_session_topic "$tpath")"
    else topic="$(sj_session_topic "$tpath")"; fi
  fi
  # model + turns in one pass (the transcript can be tens of MB); TSV, empty fields are fine.
  if declare -F sjh_session_meta >/dev/null 2>&1; then
    IFS=$'\t' read -r model turns < <(sjh_session_meta "$tpath")
  fi
  # A transcript can hold no user record at all (a resumed session whose only records are the
  # harness's own). Those ARE real sessions with a real archive entry, so they keep their row —
  # only the topic degrades. bin/sj-topics.sh can fill it in later, from the archived copy.
  [ -n "$topic" ] || topic="(no text)"
  # One writer of the "safe in a row" rule, so the backfill path cannot drift from this one.
  topic="$(sj_topic_sanitize "$topic")"
  size="$(sj_size "$tpath")" || size=0

  # Everything after `harness=` is an additive `key=value` field: a line written before a field
  # existed simply lacks it, and the readers report it as "-"/empty. A `token=` field is reserved
  # for a later pass — the readers already tolerate trailing fields they don't know.
  printf '%s | %s | %s | "%s" | session=%s | harness=%s | model=%s | turns=%s | size=%s\n' \
    "$ts" "$host" "$cwd" "$topic" "$sid" "$harness" "$model" "$turns" "$size" >> "$log"
}

# Commit + push EVERYTHING in the data repo. Shared by the session-end hook and sj-reconcile.sh:
# it is ~30 lines of hard-won wedge-proofing (see below) and must not exist twice.
#
# .gitignore blocks secrets/transcripts (*.credentials*, *.jsonl, .claude.json), so `git add -A`
# can never stage those. Best-effort and silent by contract — it must never fail its caller.
sj_data_push() {  # sj_data_push <commit-message>
  local msg="$1" data
  [ "${SCRUBJAY_LOG_NOGIT:-0}" = "1" ] && return 0
  data="$(sj_data 2>/dev/null)" || return 0
  [ -n "$data" ] && [ -d "$data/.git" ] || return 0
  (
    cd "$data" || exit 0

    # Self-heal before touching anything. A previous session's push fallback may have left an
    # interrupted rebase/merge (a conflict, or — more insidiously — a commit that went empty and
    # made rebase pause). If we don't clear it, `git add -A` below commits onto the DETACHED rebase
    # HEAD (even baking conflict markers into files), every push silently no-ops, and the wedge
    # compounds one commit per session. This is exactly the July-2026 henpi failure. Aborting is
    # safe: it just drops the partial replay; our content lives in the working tree and re-commits
    # cleanly.
    if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
      git rebase --abort 2>/dev/null || true
    elif [ -f .git/MERGE_HEAD ]; then
      git merge --abort 2>/dev/null || true
    fi
    # Commits on a detached HEAD can never push — bail rather than orphan work.
    git symbolic-ref -q HEAD >/dev/null 2>&1 || exit 0

    git add -A 2>/dev/null
    git diff --cached --quiet 2>/dev/null && exit 0   # nothing to commit
    # Never commit a tree carrying conflict markers (unambiguous start/end lines).
    git diff --cached | grep -qE '^\+(<{7} |>{7} )' && exit 0
    git commit -q -m "$msg" 2>/dev/null || exit 0
    if ! sj_timeout 20 git push -q 2>/dev/null; then
      # Remote moved on: rebase our commit onto it and retry. What makes this wedge-proof where a
      # bare `git pull --rebase` was not is that nothing here can stop on a conflict:
      #   * append-only logs union both sides (.gitattributes: logs/*.log merge=union);
      #   * for any *shared* file that genuinely diverged — e.g. plugins/known_marketplaces.json
      #     or settings — `-X ours` takes origin's copy (during a rebase "ours" is the upstream we
      #     replay onto) instead of pausing. A machine's auto-sync must never fork shared config;
      #     deliberate shared edits are made by hand, not by this fallback. A bare pull --rebase
      #     aborted on the first such conflict and left the machine's commits stacking locally
      #     forever — the July-2026 hensipi wedge.
      # Belt and suspenders: if anything still fails, abort so the next session starts clean.
      if sj_timeout 20 git fetch -q origin 2>/dev/null \
         && sj_timeout 30 git rebase -X ours -q origin/main 2>/dev/null; then
        sj_timeout 20 git push -q 2>/dev/null || true
      else
        git rebase --abort 2>/dev/null || true
      fi
    fi
  ) >/dev/null 2>&1 || true
  return 0
}

# A topic, made safe to sit in a catalogue row. The row quotes the topic and separates its fields
# with ` | `, so a stray `"` or `|` inside one derails both readers (sjmcp's _LOG regex and the
# pipe-split in sj_log_catalogue / bin/sj-catalogue.sh) — the field count shifts and the row is
# read as a different session or as no session at all. Also flattened to one line and capped, so a
# pasted paragraph cannot become a 4 KB row. One writer of this rule, two callers:
# hooks/log-session.sh when a session ends, bin/sj-topics.sh when it backfills a missing topic.
sj_topic_sanitize() {  # sj_topic_sanitize <text> [maxlen]
  local t="$1"
  t="$(printf '%s' "$t" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
  t="${t//\"/}"; t="${t//|//}"
  printf '%.*s' "${2:-100}" "$t"
}

# Rewrite one catalogue row's topic, leaving every other byte of it alone — the date, host, cwd,
# session id and trailing key=value fields are the original session's facts and must not drift.
# Anchored on the ` | "` that opens the topic and the `" | session=` that closes it, both of which
# are unambiguous because sj_topic_sanitize has already removed every other `"` from the field.
# Fails (1) on a line that is not a session row, so a caller cannot append a mangled one.
sj_log_retopic() {  # sj_log_retopic <line> <topic>
  local line="$1" topic="$2" pre post
  case "$line" in *' | "'*'" | session='*) ;; *) return 1 ;; esac
  pre="${line%%' | "'*}"
  post="${line#*'" | session='}"
  printf '%s | "%s" | session=%s' "$pre" "$topic" "$post"
}

# Every host's sessions, newest first, from the data repo's logs/ — which already carries
#   <ts> | <host> | <cwd> | "<topic>" | session=<sid> | harness=<name>
# for every session ever ended, and rides the data repo to every machine. This is the *catalogue*
# (what can I resume, and what was it about); the archive itself stays authoritative for the path,
# via transport_resolve. Emits TSV: <ts> <host> <sid> <cwd> <topic> <harness>.
#
# `harness=` only exists on lines written since scrubjay went multi-harness; older ones report "-".
#
# LAST LINE PER session= WINS. bin/sj-topics.sh gives a topic-less session a topic by *appending* a
# corrected copy of its row, never by editing the original — logs/*.log ride git with `merge=union`
# (.gitattributes) precisely because every host only ever appends to its own file, and rewriting a
# line in place forfeits that and conflicts on the next rebase. The cost of appending is that a
# session can legitimately have two rows, so every reader of these files resolves them the same
# way: the later row supersedes the earlier one. See the same rule in bin/sj-catalogue.sh and in
# mcp/sjmcp_server.py's _iter_logs.
sj_log_catalogue() {  # sj_log_catalogue [limit]
  local limit="${1:-0}" data
  data="$(sj_data)" || return 1
  awk -F' *\\| *' '
    { sid=""; harness="-"
      for (i=1; i<=NF; i++) {
        if ($i ~ /^session=/) sid=substr($i, 9)
        if ($i ~ /^harness=/) harness=substr($i, 9)
      }
      if (sid == "") next
      topic=$4; gsub(/^"|"$/, "", topic)
      row[sid] = $1 "\t" $2 "\t" sid "\t" $3 "\t" topic "\t" harness }
    END { for (s in row) print row[s] }
  ' "$data"/logs/*.log 2>/dev/null | sort -r | { [ "$limit" -gt 0 ] && head -n "$limit" || cat; }
}

# --- reading an archive that is on this filesystem --------------------------------------------
# Shared by the `local` backend (NAS mount) and the `git` backend (the scrubjay-chats clone IS the
# archive). The `rsync-wg` backend has no filesystem view of the archive — its relay key is
# write-only by design — so it reaches these same two operations over the sjmcp SSH channel
# instead. See hooks/transports/*.sh.

# Locate every archived copy of a session. The same <sid> legitimately appears under SEVERAL hosts
# once it has been handed off (each host ships into its own <host>/ subtree), so this returns all
# of them and lets the caller pick — bin/sj-resume.sh takes the longest, since a hand-off only ever
# appends turns. <sid> may be an 8-hex prefix. Emits TSV: <relpath> <lines> <mtime-epoch>.
#
# Both transcript extensions are matched: .jsonl (Claude Code, Codex) and .json (a harness whose
# session export is a single document, e.g. opencode) — see sjh_transcript_ext. The glob is pinned
# to <host>/<slug>/ so the .json records *inside* a session's sidecar dirs can never match.
#
# <sid> matches anywhere in the filename, not just as a prefix, so the 8-char handle finds its
# session whatever the id looks like: `66a71b6f` resolves `ses_66a71b6f….json` the same way it
# resolves a UUID. Several matches are expected and handled by the caller (a handed-off session
# exists under every host it ran on, and an ambiguous handle is rejected rather than guessed).
sj_archive_resolve() {  # sj_archive_resolve <root> <sid|handle>
  local root="$1" sid="$2" f rel
  [ -n "$root" ] && [ -d "$root" ] || return 1
  for f in "$root"/*/*/*"$sid"*.jsonl "$root"/*/*/*"$sid"*.json; do
    [ -f "$f" ] || continue
    rel="${f#"$root"/}"
    printf '%s\t%s\t%s\n' "$rel" "$(wc -l < "$f" 2>/dev/null || echo 0)" \
      "$(date -r "$f" +%s 2>/dev/null || echo 0)"
  done
}

# Copy one archive entry (file or directory) out to <dst>. Read-only w.r.t. the archive.
#
# The lexical check is not enough on its own: every other host writes into this archive over the
# relay, so a symlink can be *inside* it without ever appearing in the path we were handed — and
# `cp` would follow it straight out of the tree. Resolve the entry and require it to still land
# under the root, the same way bin/sjmcp-serve.sh's confine() does for the SSH read path.
sj_archive_copy() {  # sj_archive_copy <root> <relpath> <dst>
  local root="$1" rel="$2" dst="$3" src="$1/$2" real_root real_src
  case "$rel" in /*|*..*) echo "sj: refusing unsafe archive path '$rel'" >&2; return 2 ;; esac
  real_root="$(sj_realpath "$root")" || return 1
  real_src="$(sj_realpath "$src")"  || return 1
  case "$real_src" in
    "$real_root"/*) ;;
    *) echo "sj: '$rel' escapes the archive root" >&2; return 2 ;;
  esac
  if   [ -d "$real_src" ]; then mkdir -p "$dst" && cp -a "$real_src/." "$dst/"
  elif [ -f "$real_src" ]; then mkdir -p "$(dirname "$dst")" && cp -f "$real_src" "$dst"
  else return 1; fi
}
