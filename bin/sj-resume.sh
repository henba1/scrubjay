#!/usr/bin/env bash
# Cross-host session hand-off: stage an archived session from ANOTHER machine into this one's
# ~/.claude/projects/, so Claude Code's own `--resume` / `/resume` picker can continue it here.
#
#   usage: sj-resume.sh <sid|sid8> [--into <dir>] [--no-rewrite-paths] [--force]
#          sj-resume.sh --list [n]
#
# Why this is small: `claude --resume <sid>` reads exactly ONE file —
# ~/.claude/projects/<slug>/<sid>.jsonl — and scrubjay already archives that file byte-for-byte at
# <archive>/<host>/<slug>/<sid>.jsonl (bin/ship-transcript.sh), along with the session's subagents,
# tool-results, tasks and file-history. There is no session database to reconstruct. So a hand-off
# is: fetch, fix the absolute paths inside, drop it in the right local project dir. Claude Code
# does the rest.
#
# What does NOT travel: the working tree. The transcript remembers editing src/a.py at commit
# abc123 on branch X; whether that file exists here, at that commit, is git's job and yours. We
# check and warn — we do not sync code.
#
# The session id is PRESERVED (not forked), so the archive ends up holding one logical conversation
# with a per-host copy — <hostA>/<slug>/<sid>.jsonl and <hostB>/<slug>/<sid>.jsonl — and <sid8>
# stays the single handle you search by. Nothing is clobbered: each host ships into its own subtree.
# To branch instead of continue, resume with Claude's native `--fork-session`.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

die()  { echo "sj-resume: $*" >&2; exit 1; }
warn() { echo "  !  $*" >&2; }
ok()   { echo "  ✓  $*"; }
info() { echo "     $*"; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- args -------------------------------------------------------------------------------------
sid=""; into=""; rewrite=1; force=0; list=0; list_n=15
while [ $# -gt 0 ]; do
  case "$1" in
    --list)             list=1; [ $# -ge 2 ] && case "$2" in [0-9]*) list_n="$2"; shift ;; esac ;;
    --into)             into="${2:?--into needs a dir}"; shift ;;
    --no-rewrite-paths) rewrite=0 ;;
    --force)            force=1 ;;
    -*)                 die "unknown flag '$1'" ;;
    *)                  sid="$1" ;;
  esac
  shift
done

# --- the catalogue ----------------------------------------------------------------------------
# logs/<host>.log in the data repo already records every session that ever ended, on every machine,
# and rides git to this one — so "what can I resume?" needs no network at all.
if [ "$list" -eq 1 ]; then
  me="$(sj_host)"
  printf '%-10s  %-8s  %-22s  %s\n' HOST SID PROJECT TOPIC
  # Filter to *other* machines BEFORE limiting — a hand-off is by definition from another host, and
  # a busy local machine would otherwise fill the whole window with sessions you can't hand off.
  sj_log_catalogue | while IFS=$'\t' read -r _ts host s cwd topic; do
    [ "$host" = "$me" ] && continue
    printf '%-10s  %-8s  %-22s  %s\n' "$host" "${s:0:8}" "$(basename "$cwd")" "${topic:0:60}"
  done | head -n "$list_n"
  exit 0
fi

[ -n "$sid" ] || die "need a session id (or --list). usage: sj-resume.sh <sid|sid8> [--into <dir>]"

# --- the transport's read side ----------------------------------------------------------------
backend="${SCRUBJAY_TRANSCRIPT_BACKEND:-git}"
impl="$APP/hooks/transports/$backend.sh"
[ -f "$impl" ] || die "unknown backend '$backend'"
# shellcheck source=/dev/null  # backend chosen at runtime; see hooks/transports/<backend>.sh
. "$impl"
command -v transport_resolve >/dev/null 2>&1 || die "backend '$backend' has no read side"

echo "resolving ${sid:0:8} in the archive (backend: $backend)…"
cands="$(transport_resolve "$sid")" || die "could not reach the archive"
[ -n "$cands" ] || die "no archived session matches '${sid}'. Try: sj-resume.sh --list"

# A prefix can match several DIFFERENT sessions, not just the same one on several hosts — and
# silently resuming the wrong conversation would be far worse than making you retype a few hex
# digits. Only proceed when every candidate is the same session id.
sids="$(printf '%s\n' "$cands" | cut -f1 | sed 's#.*/##; s#\.jsonl$##' | sort -u)"
if [ "$(printf '%s\n' "$sids" | wc -l)" -gt 1 ]; then
  echo "sj-resume: '$sid' is ambiguous — it matches several sessions:" >&2
  printf '%s\n' "$cands" | while IFS=$'\t' read -r r l _; do
    printf '    %-40s  %s lines  (%s)\n' "$(basename "$r" .jsonl)" "$l" "${r%%/*}" >&2
  done
  die "give more of the id."
fi

# The same sid legitimately exists under SEVERAL HOSTS once it has been handed off before. A
# hand-off only ever APPENDS turns, so the longest copy is the newest state of the conversation.
best="$(printf '%s\n' "$cands" | sort -k2,2nr -k3,3nr | head -1)"
relpath="$(printf '%s' "$best" | cut -f1)"
lines="$(printf '%s'  "$best" | cut -f2)"
src_host="${relpath%%/*}"
rest="${relpath#*/}"; src_slug="${rest%%/*}"
full_sid="$(basename "$relpath" .jsonl)"

if [ "$(printf '%s\n' "$cands" | wc -l)" -gt 1 ]; then
  info "session exists on several hosts; taking the longest copy:"
  printf '%s\n' "$cands" | sort -k2,2nr | while IFS=$'\t' read -r r l _; do
    info "  ${r%%/*}  ${l} lines$([ "$r" = "$relpath" ] && echo '   <- taking this one')"
  done
fi
ok "found on '$src_host' ($lines lines)"

# --- where it lands here ----------------------------------------------------------------------
dest_cwd="${into:-$PWD}"
[ -d "$dest_cwd" ] || die "target dir does not exist: $dest_cwd"
dest_cwd="$(realpath -e "$dest_cwd")"
proj_dir="$(sj_local_project_dir "$dest_cwd")"
dest="$proj_dir/$full_sid.jsonl"

# Refuse to silently destroy local work: a longer local copy means turns happened HERE that the
# archive has never seen (a session that was never shipped, or shipped before its last turns).
if [ -f "$dest" ] && [ "$force" -eq 0 ]; then
  have="$(wc -l < "$dest")"
  if [ "$have" -gt "$lines" ]; then
    die "local copy of ${full_sid:0:8} has $have lines, the archive's has $lines — refusing to
            overwrite newer local work. Run /sjlog to publish it first, or pass --force."
  fi
fi

# --- fetch ------------------------------------------------------------------------------------
tmp="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
transport_fetch "$relpath" "$tmp/session.jsonl" || die "fetch failed: $relpath"
[ -s "$tmp/session.jsonl" ] || die "fetched an empty transcript"

# --- rewrite the absolute paths ---------------------------------------------------------------
# A transcript from another machine is full of that machine's paths. Left alone, the resumed Claude
# re-reads its own history, tries to open files that do not exist here, and burns turns
# rediscovering the repo. Rewriting them is what makes the hand-off actually usable.
#
# Done as a LITERAL substitution on the raw text, not via jq: paths inside JSON strings carry no
# escapes, so this is exact — and it leaves every other byte of the transcript untouched, where a
# jq round-trip would re-serialize the whole file (and could renormalize numbers).
esc_pat() { printf '%s' "$1" | sed 's/[][\.*^$]/\\&/g'; }
esc_rep() { printf '%s' "$1" | sed 's/[\&]/\\&/g'; }

old_cwd="$(jq -rs '[ .[] | select(.cwd != null) | .cwd ][0] // ""' "$tmp/session.jsonl")"

# The recorded cwd is not always the path Claude actually slugged: on a symlinked home (snellius
# records /home/jvrijn/… but its project dir is -gpfs-home2-jvrijn-…) the transcript BODY holds the
# resolved path. We can recover it exactly — the slug is a pure function of the real root, so walk
# the absolute paths in the file and find the ancestor whose slug is the archived one.
real_root=""
if [ -n "$old_cwd" ] && [ "$(sj_slug "$old_cwd")" != "$src_slug" ]; then
  while IFS= read -r p; do
    while [ "$p" != "/" ] && [ -n "$p" ]; do
      if [ "$(sj_slug "$p")" = "$src_slug" ]; then real_root="$p"; break 2; fi
      p="$(dirname "$p")"
    done
  done < <(grep -o '"/[^"]\{4,\}"' "$tmp/session.jsonl" | tr -d '"' | sort -u | head -2000)
fi

if [ "$rewrite" -eq 1 ] && [ -n "$old_cwd" ]; then
  D=$'\001'
  # Roots to remap, longest first so a nested root is rewritten before its parent swallows it.
  # SCRUBJAY_PATH_MAP (old:new per line, in ~/.config/scrubjay/config) covers anything we cannot
  # infer — e.g. a shared home that is /home/you here and /gpfs/home2/you there.
  maps=""
  [ -n "$real_root" ] && maps="$maps$real_root$D$dest_cwd"$'\n'
  maps="$maps$old_cwd$D$dest_cwd"$'\n'
  if [ -n "${SCRUBJAY_PATH_MAP:-}" ]; then
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      maps="$maps${pair%%:*}$D${pair#*:}"$'\n'
    done <<< "$SCRUBJAY_PATH_MAP"
  fi

  cp "$tmp/session.jsonl" "$tmp/rewritten.jsonl"
  while IFS="$D" read -r from to; do
    [ -n "$from" ] && [ "$from" != "$to" ] || continue
    sed -i "s${D}$(esc_pat "$from")${D}$(esc_rep "$to")${D}g" "$tmp/rewritten.jsonl"
    info "rewrote  $from  ->  $to"
  done < <(printf '%s' "$maps" | awk -F"$D" '{ print length($1)"\t"$0 }' | sort -rn | cut -f2-)

  # Never install a transcript we might have broken: same number of records, and every one still
  # parses. If either check fails, fall back to the verbatim archive copy and say so.
  if [ "$(wc -l < "$tmp/rewritten.jsonl")" -eq "$(wc -l < "$tmp/session.jsonl")" ] \
     && jq -c . "$tmp/rewritten.jsonl" >/dev/null 2>&1; then
    mv "$tmp/rewritten.jsonl" "$tmp/session.jsonl"
    ok "paths rewritten and validated ($(wc -l < "$tmp/session.jsonl") records)"
  else
    warn "path rewrite produced invalid JSONL — installing the transcript VERBATIM instead."
    warn "the resumed session will reference '$old_cwd', which does not exist here."
  fi
elif [ "$rewrite" -eq 1 ]; then
  warn "no cwd recorded in the transcript — installing verbatim, paths not rewritten"
fi

# --- install ----------------------------------------------------------------------------------
mkdir -p "$proj_dir" || die "cannot create $proj_dir"
if [ -f "$dest" ]; then cp -f "$dest" "$dest.bak" && info "backed up existing copy -> $(basename "$dest").bak"; fi
cp -f "$tmp/session.jsonl" "$dest" || die "could not write $dest"
ok "staged $dest"

# The session's siblings: subagent transcripts + tool-results live in <sid>/, and ship-transcript.sh
# tucks tasks/ and file-history/ in there too. Split them back to where Claude Code expects them.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if transport_fetch "$src_host/$src_slug/$full_sid" "$tmp/side" 2>/dev/null && [ -d "$tmp/side" ]; then
  if [ -d "$tmp/side/tasks" ]; then
    mkdir -p "$CLAUDE_DIR/tasks/$full_sid" && cp -a "$tmp/side/tasks/." "$CLAUDE_DIR/tasks/$full_sid/" \
      && ok "restored task list"
  fi
  if [ -d "$tmp/side/file-history" ]; then
    mkdir -p "$CLAUDE_DIR/file-history/$full_sid" \
      && cp -a "$tmp/side/file-history/." "$CLAUDE_DIR/file-history/$full_sid/" \
      && ok "restored file history (/rewind will work)"
  fi
  rm -rf "$tmp/side/tasks" "$tmp/side/file-history"
  if [ -n "$(ls -A "$tmp/side" 2>/dev/null)" ]; then
    mkdir -p "$proj_dir/$full_sid" && cp -a "$tmp/side/." "$proj_dir/$full_sid/" \
      && ok "restored subagent transcripts + tool results"
  fi
fi

# --- the part that does NOT travel ------------------------------------------------------------
# The transcript came over; the code did not. Say so plainly rather than letting the resumed session
# discover it by failing.
branch="$(jq -rs '[ .[] | select(.gitBranch != null and .gitBranch != "") | .gitBranch ] | last // ""' "$tmp/session.jsonl" 2>/dev/null)"
if git -C "$dest_cwd" rev-parse --git-dir >/dev/null 2>&1; then
  here="$(git -C "$dest_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -n "$branch" ] && [ "$branch" != "$here" ]; then
    warn "the session was on branch '$branch'; this checkout is on '$here'"
    info "  the conversation remembers files as they were on '$branch' — switch, or expect drift"
  elif [ -n "$branch" ]; then
    ok "branch matches ($branch)"
  fi
  [ -n "$(git -C "$dest_cwd" status --porcelain 2>/dev/null)" ] && \
    warn "the working tree here has uncommitted changes — the session has not seen them"
elif [ -n "$branch" ]; then
  warn "the session was on git branch '$branch', but $dest_cwd is not a git repo"
fi

echo
echo "  ready — continue the conversation from '$src_host' with:"
echo
echo "      claude --resume $full_sid"
echo
echo "  (or, inside a Claude session in this directory, run /resume and pick ${full_sid:0:8}.)"
echo "  To branch instead of continue:  claude --resume $full_sid --fork-session"
