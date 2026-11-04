#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# `claude resume <sid>` from a plain terminal, for a session that may have been recorded on ANOTHER
# machine. The `claude` shell function in bin/sj-shell.sh calls this; nothing else does.
#
#   usage: sj-claude-resume.sh <sid|prefix> [claude args…]
#
# It finds the session, makes sure Claude Code can see it from here, and then replaces itself with
# the real `claude --resume <full-sid> [claude args…]`:
#
#   1. Expand the prefix to ONE session id — from this machine's own transcripts plus the
#      cross-machine catalogue (logs/<host>.log in the data repo, which rides git, so no network).
#      Several distinct sessions match → list them and stop. A wrong conversation is worse than
#      typing two more hex digits.
#   2. Already on this machine → just resume it. In this folder's project dir as-is; in another
#      folder's (Claude only looks in the one for the cwd) by running it from that folder, when the
#      folder still exists here.
#   3. Otherwise stage it with bin/sj-resume.sh — the same hand-off /sjresume does, into the folder
#      you are standing in, rewriting the other host's paths to it — with --no-clobber, so an
#      existing local transcript is never replaced by a different one.
#
# A session from a different coding agent cannot be resumed by `claude`; sj-resume.sh renders it as
# context instead, and this prints the command to continue it rather than pretending to resume.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config
sj_load_adapter claude || exit 1

say() { echo "scrubjay: $*" >&2; }

# The real binary. `command` skips the shell function that brought us here — functions are not
# inherited by this process anyway — and SCRUBJAY_CLAUDE_BIN lets a test aim it at a stub.
run_claude() {  # run_claude <args…>   — never returns
  local bin="${SCRUBJAY_CLAUDE_BIN:-claude}"
  command -v "$bin" >/dev/null 2>&1 || { say "'$bin' is not on PATH"; exit 127; }
  exec "$bin" "$@"
}

if [ $# -lt 1 ] || [ -z "$1" ]; then echo "usage: sj-claude-resume.sh <sid|prefix> [claude args…]" >&2; exit 2; fi
want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; shift
case "$want" in *[!0-9a-f-]*) say "'$want' is not a session id (hex, optionally with dashes)"; exit 2 ;; esac
proj_root="$(sjh_config_dir)/projects"

# --- 1. which session? ---------------------------------------------------------------------------
# Local transcripts first: exactly projects/<slug>/<sid>.jsonl, never a subagent's nested one.
local_hits="$(find "$proj_root" -mindepth 2 -maxdepth 2 -type f -name "$want*.jsonl" 2>/dev/null)"
catalogue="$(sj_log_catalogue 2>/dev/null | awk -F'\t' -v p="$want" 'index($3, p) == 1')"

sids="$( { [ -n "$local_hits" ] && printf '%s\n' "$local_hits" | sed 's#.*/##; s#\.jsonl$##'
           [ -n "$catalogue" ]  && printf '%s\n' "$catalogue" | cut -f3; } | sort -u)"
n="$(printf '%s' "$sids" | grep -c . || true)"

if [ "$n" -gt 1 ]; then
  say "'$want' matches $n sessions — give more of the id:"
  printf '%s\n' "$sids" | while IFS= read -r s; do
    row="$(printf '%s\n' "$catalogue" | awk -F'\t' -v s="$s" '$3 == s' | head -1)"
    if [ -n "$row" ]; then
      IFS=$'\t' read -r ts host _ cwd topic _ <<< "$row"
      printf '    %-36s  %-10s  %-16s  %-24s  %s\n' "$s" "$host" "$ts" "$(sj_pretty_path "$cwd")" "${topic:0:48}" >&2
    else
      printf '    %-36s  %-10s  %s\n' "$s" "(here)" \
        "$(sj_pretty_path "$(printf '%s\n' "$local_hits" | grep -F "/$s.jsonl" | head -1)")" >&2
    fi
  done
  exit 2
fi
full="$sids"   # one id, or empty when neither knows it (sj-resume.sh still asks the archive)

# --- 2. already here? ----------------------------------------------------------------------------
if [ -n "$full" ]; then
  here_dir="$(sjh_project_dir "$PWD")"
  if [ -f "$here_dir/$full.jsonl" ]; then
    run_claude --resume "$full" "$@"
  fi
  local_copy="$(printf '%s\n' "$local_hits" | grep -F "/$full.jsonl" | head -1)"
  if [ -n "$local_copy" ]; then
    rec_cwd="$(sjh_session_cwd "$local_copy")"
    if [ -n "$rec_cwd" ] && [ -d "$rec_cwd" ]; then
      say "${full:0:8} is a session from $(sj_pretty_path "$rec_cwd") on this machine — resuming it there."
      cd "$rec_cwd" || exit 1
      run_claude --resume "$full" "$@"
    fi
    say "${full:0:8} is on this machine ($(sj_pretty_path "$local_copy")), but its folder"
    say "'${rec_cwd:-?}' does not exist here — staging the archived copy into $(sj_pretty_path "$PWD") instead."
  fi
fi

# --- 3. hand it off from the archive ------------------------------------------------------------
row="$( [ -n "$full" ] && printf '%s\n' "$catalogue" | awk -F'\t' -v s="$full" '$3 == s' | head -1)"
if [ -n "$row" ]; then
  IFS=$'\t' read -r ts host _ cwd _ <<< "$row"
  say "${full:0:8} was recorded on '$host' in $cwd ($ts) — staging it into $(sj_pretty_path "$PWD")"
  if [ "$cwd" != "$PWD" ] && [ -d "$cwd" ]; then
    say "  ($cwd exists here too. To continue it there instead: cd $cwd && claude resume ${full:0:8})"
  fi
fi

# --json: the narration still reaches the terminal (stderr); stdout is the one outcome object.
json="$(bash "$APP/bin/sj-resume.sh" "${full:-$want}" --no-clobber --json)" || exit 1
[ "$(printf '%s' "$json" | jq -r '.ok' 2>/dev/null)" = true ] || exit 1

sid="$(printf '%s' "$json" | jq -r '.sid')"
case "$(printf '%s' "$json" | jq -r '.mode')" in
  native)
    say "starting: claude --resume $sid${*:+ $*}"
    run_claude --resume "$sid" "$@" ;;
  *)
    # Another agent's session: there is no Claude session to resume. sj-resume.sh has already said
    # so and printed the command that carries the conversation over; do not run one on its behalf.
    exit 0 ;;
esac
