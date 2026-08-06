#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# One-shot: put this machine's BACK CATALOGUE into the archive. The SessionEnd hook only ships
# sessions that end after scrubjay went live, so every conversation from before onboarding is
# invisible to /sjrecall until something backfills it — this is that something.
#
# Two steps, because shipping and reading are different layers:
#   1) bin/backfill-transcripts.sh — the raw <host>/<slug>/<sid>.jsonl records
#   2) bin/backfill-readable.sh    — the Markdown `readable/` tree that /sjrecall actually greps
# On the `git` backend step 1 is a plain `cp` into the scrubjay-chats clone (no rendering), so
# without step 2 the archive holds transcripts that recall cannot see. That gap is the whole
# reason this wrapper exists — running one script and assuming you are done is the failure mode.
#
# Idempotent: re-running ships only what changed, and re-renders in place.
#
#   usage: sj-backfill.sh [--host NAME] [--no-readable] [--no-push]
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }

READABLE=1; PUSH=1; HOST_ARG=()
while [ $# -gt 0 ]; do
  case "$1" in
    --host)         HOST_ARG=(--host "${2:?--host needs a name}"); CLAUDE_HOST="$2"; export CLAUDE_HOST; shift 2;;
    --no-readable)  READABLE=0; shift;;
    --no-push)      PUSH=0; shift;;
    # Skip the shebang + SPDX block (lines 1-3) and the blank line under it, so --help prints the
    # usage prose rather than the licence header (which is all the NR>1 form elsewhere manages).
    -h|--help)      awk 'NR<=3 {next} /^$/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0;;
    -v|--version)   echo "scrubjay $(sj_version)"; exit 0;;
    *)              warn "unknown argument: $1"; exit 2;;
  esac
done

HOST="$(sj_host)"
BACKEND="${SCRUBJAY_TRANSCRIPT_BACKEND:-git}"
[ "$BACKEND" != off ] || { warn "transcript backend is 'off' — nothing to backfill to."; exit 0; }

echo; info "backfilling the back catalogue  (host: $HOST, backend: $BACKEND)"

# ---- 1) raw transcripts ---------------------------------------------------------------
bash "$APP/bin/backfill-transcripts.sh" "${HOST_ARG[@]}" || { warn "transcript backfill failed"; exit 1; }

# ---- 2) the readable layer ------------------------------------------------------------
# rsync-wg ships through ship-transcript.sh, which renders readable on the way out — the archive
# is on the far end, so there is nothing local to render here.
if [ "$READABLE" = 0 ]; then
  info "skipping the readable layer (--no-readable) — /sjrecall will not see these until it is built"
elif [ "$BACKEND" = rsync-wg ]; then
  info "readable/ is rendered by ship-transcript.sh on the way out for rsync-wg — nothing to do here"
else
  root="${SCRUBJAY_LOCAL_CHATS:-$(sj_chats)}"
  if [ -n "$root" ] && [ -d "$root" ]; then
    bash "$APP/bin/backfill-readable.sh" "$root" || warn "readable rendering had issues"
  else
    warn "no archive root found (SCRUBJAY_LOCAL_CHATS / SCRUBJAY_CHATS) — skipped the readable layer"
  fi
fi

# ---- 3) publish ------------------------------------------------------------------------
# backfill-transcripts.sh already committed+pushed the .jsonl on the git backend, but the readable
# tree is generated AFTER that, so it needs its own commit — otherwise it sits untracked and the
# next machine never sees it.
if [ "$BACKEND" = git ]; then
  chats="$(sj_chats)"
  if [ -n "$chats" ] && [ -d "$chats/.git" ]; then
    if ( cd "$chats" && git add -A && ! git diff --cached --quiet ); then
      n="$(cd "$chats" && git diff --cached --numstat | wc -l | tr -d ' ')"
      ( cd "$chats" && git commit -q -m "backfill: readable renderings from $HOST" ) || warn "commit failed"
      if [ "$PUSH" = 1 ]; then
        if ( cd "$chats" && sj_timeout 300 git push -q ); then ok "pushed $n readable file(s)"
        else warn "committed $n file(s); push failed (goes out on the next push)"; fi
      else
        info "committed $n readable file(s); not pushing (--no-push)"
      fi
    else
      ok "readable layer already up to date — nothing to publish"
    fi
  fi
fi

echo; ok "backfill complete for '$HOST'"
info "Check it with:  /sjrecall <topic>   or   bin/sj-doctor.sh"
