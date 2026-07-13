#!/usr/bin/env bash
# Shared helpers for the scrubjay app. Source this; do not execute.
# The app (logic) is this repo; personal content lives in a separate data repo, and
# transcripts in a separate relay repo. Pointers come from ~/.config/scrubjay/config.

sj_load_config() {
  [ -f "$HOME/.config/scrubjay/config" ] && . "$HOME/.config/scrubjay/config"
  : "${SCRUBJAY_TRANSCRIPT_BACKEND:=git}"
}

# Absolute path of the app repo (this file lives in <app>/bin/).
sj_app() { (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

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

# The session's first real user prompt, as one line of plain text ("" if there isn't one).
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
#   real user prompt, slugified). Derived from the .jsonl itself so it also works for backfill.
sj_readable_relpath() {  # sj_readable_relpath <transcript.jsonl> <session_id>
  local src="$1" sid="$2" cwd project topic d
  if ! command -v jq >/dev/null 2>&1; then printf 'misc/%s' "${sid:0:8}"; return; fi
  cwd="$(jq -rs '[ .[] | select(.cwd!=null) | .cwd ][0] // ""' "$src" 2>/dev/null)"
  project="$(basename "${cwd:-misc}")"; [ -n "$project" ] && [ "$project" != "/" ] || project="misc"
  topic="$(sj_session_topic "$src")"
  topic="$(printf '%s' "$topic" | tr "[:upper:]" "[:lower:]" | tr -cs "a-z0-9" "-" \
            | sed -E "s/^-+//; s/-+$//" | cut -c1-40 | sed -E "s/-+$//")"
  [ -n "$topic" ] || topic="session"
  d="$(date -r "$src" +%F 2>/dev/null || date +%F)"
  printf '%s/%s_%s__%s' "$project" "$d" "$topic" "${sid:0:8}"
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
# Claude Code stores a session at ~/.claude/projects/<slug>/<sid>.jsonl, where <slug> is the
# session's absolute cwd with every character outside [A-Za-z0-9-] replaced by '-'. The encoding
# is LOSSY (a '-' may have been '/', '_', '.' or a space), so scrubjay never decodes a slug — it
# stores the one Claude used, verbatim, and recomputes a *local* one when importing.

# Claude Code's project-dir encoding. Verified against the archive: '/', '_', '.' and spaces all
# collapse to '-'; letters, digits and existing '-' pass through with case preserved.
sj_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9-]/-/g'; }

# The ~/.claude/projects/ dir that holds sessions for <cwd> (default: $PWD). Prefer *asking the
# archive of local sessions* — find the dir whose transcripts record this cwd — because that is
# exact and survives the edge cases sj_slug() cannot see (e.g. a symlinked home: snellius records
# cwd=/home/jvrijn/… but Claude slugged the resolved /gpfs/home2/jvrijn/…). Fall back to encoding
# the resolved path, which is all we can do for a project that has no sessions on this host yet.
sj_local_project_dir() {  # sj_local_project_dir [cwd]
  local cwd="${1:-$PWD}" proj d f real
  proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  for d in "$proj"/*/; do
    [ -d "$d" ] || continue
    f="$(ls -t "$d"*.jsonl 2>/dev/null | head -1)" || continue
    [ -n "$f" ] || continue
    if grep -qF "\"cwd\":\"$cwd\"" "$f" 2>/dev/null; then printf '%s' "${d%/}"; return 0; fi
  done
  real="$(realpath -e "$cwd" 2>/dev/null || printf '%s' "$cwd")"
  printf '%s/%s' "$proj" "$(sj_slug "$real")"
}

# Every host's sessions, newest first, from the data repo's logs/ — which already carries
#   <ts> | <host> | <cwd> | "<topic>" | session=<sid>
# for every session ever ended, and rides the data repo to every machine. This is the *catalogue*
# (what can I resume, and what was it about); the archive itself stays authoritative for the path,
# via transport_resolve. Emits TSV: <ts> <host> <sid> <cwd> <topic>.
sj_log_catalogue() {  # sj_log_catalogue [limit]
  local limit="${1:-0}" data
  data="$(sj_data)" || return 1
  awk -F' *\\| *' '
    { sid=""; for (i=1; i<=NF; i++) if ($i ~ /^session=/) { sid=substr($i, 9) }
      if (sid == "") next
      topic=$4; gsub(/^"|"$/, "", topic)
      printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, sid, $3, topic }
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
sj_archive_resolve() {  # sj_archive_resolve <root> <sid|sid8>
  local root="$1" sid="$2" f rel
  [ -n "$root" ] && [ -d "$root" ] || return 1
  for f in "$root"/*/*/"$sid"*.jsonl; do
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
  real_root="$(realpath -e "$root" 2>/dev/null)" || return 1
  real_src="$(realpath -e "$src"  2>/dev/null)" || return 1
  case "$real_src" in
    "$real_root"/*) ;;
    *) echo "sj: '$rel' escapes the archive root" >&2; return 2 ;;
  esac
  if   [ -d "$real_src" ]; then mkdir -p "$dst" && cp -a "$real_src/." "$dst/"
  elif [ -f "$real_src" ]; then mkdir -p "$(dirname "$dst")" && cp -f "$real_src" "$dst"
  else return 1; fi
}
