#!/usr/bin/env bash
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
# `.message.content` is a string on some records and an ARRAY of content blocks on others — which
# is the common shape for a typed prompt. Reading only the string form silently drops most
# sessions, so normalize the array to its joined text blocks first (tool_result / image blocks
# carry no prompt and are skipped). Then discard the records that are not the user *talking*:
# the injected `<...>` blocks (system-reminder, command-name, local-command output) and the
# "Caveat:" preamble.
sj_session_topic() {  # sj_session_topic <transcript.jsonl>
  jq -rs '[ .[] | select(.type=="user") | .message.content
            | if type=="array" then [ .[] | select(.type=="text") | .text ] | join(" ") else . end
            | select(type=="string")
            | sub("^\\s+"; "") | sub("\\s+$"; "")
            | select(. != "" and ((startswith("<") or startswith("Caveat")) | not)) ][0] // ""' \
    "$1" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/^ *//; s/ *$//'
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
  topic="$(printf '%s' "$topic" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-" \
            | sed -E "s/^-+//; s/-+$//" | cut -c1-40 | sed -E "s/-+$//")"
  [ -n "$topic" ] || topic="session"
  d="$(date -r "$src" +%F 2>/dev/null || date +%F)"
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
  local dir="$1" f base topic d target n
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*) continue ;; esac
    topic="$(grep -m1 -E '^#+[[:space:]]+' "$f" 2>/dev/null \
              | sed -E 's/^#+[[:space:]]+//; s/^[Pp]lan[[:space:]]*[:-][[:space:]]*//')"
    topic="$(printf '%s' "$topic" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-" \
              | sed -E "s/^-+//; s/-+$//" | cut -c1-50 | sed -E "s/-+$//")"
    [ -n "$topic" ] || topic="${base%.md}"
    d="$(date -r "$f" +%F 2>/dev/null || date +%F)"
    target="$dir/${d}_${topic}.md"
    if [ -e "$target" ] && [ "$target" != "$f" ]; then
      n=2; while [ -e "$dir/${d}_${topic}-${n}.md" ]; do n=$((n + 1)); done
      target="$dir/${d}_${topic}-${n}.md"
    fi
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

# --- session hand-off (bin/sj-resume.sh) ------------------------------------------------------
# Where a session lives locally, and how a harness encodes a project into a directory name, are
# harness-specific — they moved to bin/adapters/<harness>.sh (sjh_project_dir / sjh_slug).

# Every host's sessions, newest first, from the data repo's logs/ — which already carries
#   <ts> | <host> | <cwd> | "<topic>" | session=<sid> | harness=<name>
# for every session ever ended, and rides the data repo to every machine. This is the *catalogue*
# (what can I resume, and what was it about); the archive itself stays authoritative for the path,
# via transport_resolve. Emits TSV: <ts> <host> <sid> <cwd> <topic> <harness>.
#
# `harness=` only exists on lines written since scrubjay went multi-harness; older ones report "-".
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
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, sid, $3, topic, harness }
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
