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

# A hand-off has TWO harnesses, and conflating them is a bug:
#   SOURCE — the harness that produced the archived session. It owns how the file is read: its cwd,
#            its project-slug encoding, its renderer. Detected from the records themselves
#            (sj_detect_harness), because the archive is deliberately harness-neutral.
#   TARGET — the harness you are resuming IN (this one). It owns where the session is installed and
#            how it is continued.
# They are usually the same. When they are not, there is no native session to resume — see the
# cross-harness branch at the bottom, and the open issue in bin/adapters/ROADMAP.md.
tgt_harness="$(sj_harness)"
sj_load_adapter "$tgt_harness" || exit 1

die()  { echo "sj-resume: $*" >&2; exit 1; }
warn() { echo "  !  $*" >&2; }
ok()   { echo "  ✓  $*"; }
info() { echo "     $*"; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- args -------------------------------------------------------------------------------------
# --import (default, where the harness supports it) installs the session into the target harness
# rather than leaving the user to paste a two-step command. --no-import stages only.
sid=""; into=""; rewrite=1; force=0; list=0; list_n=15; do_import=1
while [ $# -gt 0 ]; do
  case "$1" in
    --list)             list=1; [ $# -ge 2 ] && case "$2" in [0-9]*) list_n="$2"; shift ;; esac ;;
    --into)             into="${2:?--into needs a dir}"; shift ;;
    --no-rewrite-paths) rewrite=0 ;;
    --import)           do_import=1 ;;
    --no-import)        do_import=0 ;;
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
  printf '%-10s  %-9s  %-8s  %-20s  %s\n' HOST HARNESS SID PROJECT TOPIC
  # Filter to *other* machines BEFORE limiting — a hand-off is by definition from another host, and
  # a busy local machine would otherwise fill the whole window with sessions you can't hand off.
  # HARNESS matters now: a session from another agent can be carried over, but not natively resumed.
  sj_log_catalogue | while IFS=$'\t' read -r _ts host s cwd topic harness; do
    [ "$host" = "$me" ] && continue
    printf '%-10s  %-9s  %-8s  %-20s  %s\n' \
      "$host" "${harness:--}" "${s:0:8}" "$(basename "$cwd")" "${topic:0:52}"
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
sids="$(printf '%s\n' "$cands" | cut -f1 | sed 's#.*/##; s#\.[^.]*$##' | sort -u)"
if [ "$(printf '%s\n' "$sids" | wc -l)" -gt 1 ]; then
  echo "sj-resume: '$sid' is ambiguous — it matches several sessions:" >&2
  printf '%s\n' "$cands" | while IFS=$'\t' read -r r l _; do
    b="$(basename "$r")"
    printf '    %-40s  %s lines  (%s)\n' "${b%.*}" "$l" "${r%%/*}" >&2
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
full_sid="$(basename "$relpath")"; full_sid="${full_sid%.*}"

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
dest_cwd="$(sj_realpath "$dest_cwd")"

# --- fetch ------------------------------------------------------------------------------------
# The archived name already carries the format (.jsonl / .json) — take the extension from there
# rather than from an adapter, because we do not yet know which harness wrote it.
src_ext="${relpath##*.}"; [ "$src_ext" != "$relpath" ] || src_ext="jsonl"
tmp="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
raw="$tmp/session.$src_ext"
transport_fetch "$relpath" "$raw" || die "fetch failed: $relpath"
[ -s "$raw" ] || die "fetched an empty transcript"

# --- whose session is this? --------------------------------------------------------------------
# The archive is harness-neutral, so nothing in the path says which agent produced this session —
# the records do. Getting this wrong is not cosmetic: it is what made an earlier version hand a
# Claude .jsonl to `opencode import`, which cannot possibly load it.
src_harness="$(sj_detect_harness "$raw")" \
  || die "cannot tell which harness produced ${full_sid:0:8} (unrecognized transcript format)"
if [ "$src_harness" = "$tgt_harness" ]; then
  ok "source: $src_harness (same harness — native resume)"
else
  info "source: $src_harness   target: $tgt_harness   (cross-harness)"
fi

# --- rewrite the absolute paths ---------------------------------------------------------------
# A transcript from another machine is full of that machine's paths. Left alone, the resumed agent
# re-reads its own history, tries to open files that do not exist here, and burns turns
# rediscovering the repo. Rewriting them is what makes the hand-off actually usable.
#
# Done as a LITERAL substitution on the raw text, not via jq: paths inside JSON strings carry no
# escapes, so this is exact — and it leaves every other byte of the transcript untouched, where a
# jq round-trip would re-serialize the whole file (and could renormalize numbers).
#
# Reading the transcript is the SOURCE harness's job (its cwd lives in a different place in every
# format), so those calls go through sj_adapter_call — the target adapter is the one loaded here.
esc_pat() { printf '%s' "$1" | sed 's/[][\.*^$]/\\&/g'; }
esc_rep() { printf '%s' "$1" | sed 's/[\&]/\\&/g'; }

old_cwd="$(sj_adapter_call "$src_harness" sjh_session_cwd "$raw")"

# The recorded cwd is not always the path the harness actually slugged: on a symlinked home
# (snellius records /home/jvrijn/… but its project dir is -gpfs-home2-jvrijn-…) the transcript BODY
# holds the resolved path. We can recover it exactly — the slug is a pure function of the real root,
# so walk the absolute paths in the file and find the ancestor whose slug is the archived one.
real_root=""
if [ -n "$old_cwd" ] && [ "$(sj_adapter_call "$src_harness" sjh_slug "$old_cwd")" != "$src_slug" ]; then
  while IFS= read -r p; do
    while [ "$p" != "/" ] && [ -n "$p" ]; do
      if [ "$(sj_adapter_call "$src_harness" sjh_slug "$p")" = "$src_slug" ]; then real_root="$p"; break 2; fi
      p="$(dirname "$p")"
    done
  done < <(grep -o '"/[^"]\{4,\}"' "$raw" | tr -d '"' | sort -u | head -2000)
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

  cp "$raw" "$tmp/rewritten"
  while IFS="$D" read -r from to; do
    [ -n "$from" ] && [ "$from" != "$to" ] || continue
    sj_sed_i "s${D}$(esc_pat "$from")${D}$(esc_rep "$to")${D}g" "$tmp/rewritten"
    info "rewrote  $from  ->  $to"
  done < <(printf '%s' "$maps" | awk -F"$D" '{ print length($1)"\t"$0 }' | sort -rn | cut -f2-)

  # Never install a transcript we might have broken: same number of records, and every one still
  # parses. (Both hold for a single-document export too — one line, one value.) If either check
  # fails, fall back to the verbatim archive copy and say so.
  if [ "$(wc -l < "$tmp/rewritten")" -eq "$(wc -l < "$raw")" ] \
     && jq -c . "$tmp/rewritten" >/dev/null 2>&1; then
    mv "$tmp/rewritten" "$raw"
    ok "paths rewritten and validated ($(wc -l < "$raw") records)"
  else
    warn "path rewrite produced invalid JSON — installing the transcript VERBATIM instead."
    warn "the resumed session will reference '$old_cwd', which does not exist here."
  fi
elif [ "$rewrite" -eq 1 ]; then
  warn "no cwd recorded in the transcript — installing verbatim, paths not rewritten"
fi

# --- cross-harness: carry the CONVERSATION over, don't fake a session --------------------------
# A session from another agent cannot be resumed natively: its records are in that agent's format,
# and nothing here can turn them into this one's (see bin/adapters/ROADMAP.md — "true translation"
# is an open issue). Rather than stage a file the target cannot load, hand the conversation over as
# context: render the source's readable Markdown — the one artifact every harness shares — and start
# a NEW session from it. You continue the conversation; you do not inherit the session id.
if [ "$src_harness" != "$tgt_harness" ]; then
  inbox="${XDG_DATA_HOME:-$HOME/.local/share}/scrubjay/inbox/$tgt_harness"
  mkdir -p "$inbox" || die "cannot create $inbox"
  primer="$inbox/${full_sid}.md"
  sj_adapter_call "$src_harness" sjh_render "$raw" > "$primer" 2>/dev/null
  [ -s "$primer" ] || die "could not render the $src_harness session into readable form"
  ok "rendered the $src_harness session as context -> $primer"
  echo
  echo "  '$full_sid' is a **$src_harness** session, and $tgt_harness cannot resume it natively."
  echo "  Continue the conversation in $tgt_harness with:"
  echo
  echo "      $(sjh_context_cmd "$primer" "$src_host" "$src_harness")"
  echo
  info "this carries the conversation, not the session id — tool history and /rewind stay behind."
  info "to continue it natively instead, run this from a $src_harness session."
  exit 0
fi

# --- native install (same harness) --------------------------------------------------------------
proj_dir="$(sjh_project_dir "$dest_cwd")"
dest="$proj_dir/$full_sid.$src_ext"

# Refuse to silently destroy local work: a longer local copy means turns happened HERE that the
# archive has never seen (a session that was never shipped, or shipped before its last turns).
if [ -f "$dest" ] && [ "$force" -eq 0 ]; then
  have="$(wc -l < "$dest")"
  if [ "$have" -gt "$lines" ]; then
    die "local copy of ${full_sid:0:8} has $have lines, the archive's has $lines — refusing to
            overwrite newer local work. Run /sjlog to publish it first, or pass --force."
  fi
fi

mkdir -p "$proj_dir" || die "cannot create $proj_dir"
if [ -f "$dest" ]; then cp -f "$dest" "$dest.bak" && info "backed up existing copy -> $(basename "$dest").bak"; fi
cp -f "$raw" "$dest" || die "could not write $dest"
ok "staged $dest"

# The session's siblings: subagent transcripts + tool-results live in <sid>/, and ship-transcript.sh
# tucks tasks/ and file-history/ in there too. The adapter splits them back to wherever this harness
# expects to find them (the mirror image of sjh_extra_artifacts).
if transport_fetch "$src_host/$src_slug/$full_sid" "$tmp/side" 2>/dev/null && [ -d "$tmp/side" ]; then
  sjh_import_side "$full_sid" "$tmp/side" "$proj_dir"
fi

# --- the part that does NOT travel ------------------------------------------------------------
# The transcript came over; the code did not. Say so plainly rather than letting the resumed session
# discover it by failing.
branch="$(jq -rs '[ .. | objects | select(has("gitBranch")) | .gitBranch | select(. != null and . != "") ] | last // ""' "$raw" 2>/dev/null)"
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

# --- install into the harness ------------------------------------------------------------------
# Some harnesses read the staged transcript straight from disk (Claude); others keep sessions in a
# database and must be told to ingest it (opencode). Where the adapter can do that, do it — leaving
# the user to copy-paste a two-step `import && resume` is a workaround, not a hand-off.
installed=0
if [ "$do_import" -eq 1 ] && declare -F sjh_install_session >/dev/null 2>&1; then
  if sjh_install_session "$dest" "$dest_cwd" "$full_sid"; then
    installed=1; ok "imported into $tgt_harness"
  else
    warn "could not import into $tgt_harness — falling back to the manual command below"
  fi
fi

echo
echo "  ready — continue the conversation from '$src_host' with:"
echo
echo "      $(sjh_resume_cmd "$full_sid" "$dest" "$installed")"
echo
echo "  (or, inside a session in this directory, run /resume and pick ${full_sid:0:8}.)"
if [ "$tgt_harness" = claude ]; then
  echo "  To branch instead of continue:  claude --resume $full_sid --fork-session"
fi
exit 0
