#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# One-off: build the human-readable Markdown `readable/` tree for transcripts already in the
# archive. Run where the archive lives. Idempotent (re-renders, overwrites).
#   usage: backfill-readable.sh [chats-root]
#          defaults to $SCRUBJAY_LOCAL_CHATS, else the scrubjay-chats clone ($SCRUBJAY_CHATS)
set -uo pipefail
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$APP/bin/lib.sh"; sj_load_config
root="${1:-${SCRUBJAY_LOCAL_CHATS:-}}"
# SCRUBJAY_LOCAL_CHATS is only ever set for the `local` backend. On `git` there is no NAS mount —
# the scrubjay-chats clone IS the archive (same <host>/<slug>/ tree), and backfill-transcripts.sh
# copies raw .jsonl into it without rendering. Falling back to it is what makes the readable layer
# (and therefore /sjrecall) reachable on the git backend instead of exiting on `usage:`.
[ -n "$root" ] || root="$(sj_chats)"
[ -n "$root" ] && [ -d "$root" ] || { echo "usage: backfill-readable.sh <chats-root>" >&2; exit 1; }

n=0
while IFS= read -r f; do
  rel="${f#"$root"/}"; host="${rel%%/*}"          # <host>/<slug>/<sid>.jsonl
  sid="$(basename "$f" .jsonl)"
  out="$root/$host/readable/$(sj_readable_relpath "$f" "$sid").md"
  mkdir -p "$(dirname "$out")" || continue
  bash "$APP/bin/render-transcript.sh" "$f" > "$out" 2>/dev/null && n=$((n+1))
done < <(find "$root" -type f -name '*.jsonl' \
              ! -path '*/readable/*' ! -path '*/subagents/*' ! -name 'agent-*')
echo "rendered $n transcript(s) into */readable/ under $root"
