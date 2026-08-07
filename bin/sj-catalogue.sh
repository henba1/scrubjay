#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Render the cross-machine session catalogue as a human-browsable Markdown table.
#
#   <data>/logs/*.log          the source of truth — one appended line per session, per host
#     -> <data>/logs/CATALOGUE.md   derived — every host's sessions, newest first, aligned
#
# This exists so that browsing your own chat history costs nothing: open the file in any editor
# instead of paying ~2.8k tokens for the `/sjbrowse` -> sj_list round-trip that renders the same
# rows. The MCP tools remain how an *agent* reads the catalogue; this is how a *human* does.
#
# DERIVED — NEVER COMMITTED. logs/*.log can ride git with `merge=union` (.gitattributes) because
# each host only ever appends to its own file. A regenerated whole-file table has no such
# property: two machines would conflict on it on every rebase — the exact wedge class that
# log-session.sh goes to such lengths to avoid. So CATALOGUE.md is .gitignore'd and rebuilt
# locally from the synced logs, on SessionStart (after the pull) and SessionEnd (after the
# append). The logs sync; the table is a local view of them.
#
# Unlike sj_list, this filters NOTHING: a session whose topic never got summarized still gets a
# row, with the topic column blank. It is still a real session with a resumable id, and a blank
# cell is honest where a silent omission is not.
#
# It PULLS the data repo first, because the question this file answers — "what chats exist, on
# every machine?" — is wrong by definition if another host has pushed since. Rendering stale logs
# without saying so is how you conclude a sync is broken when it is merely behind. `--no-pull` is
# for callers that already handle git (the hooks); the pull is best-effort and never blocks a
# render, but a skipped/failed one is stamped into the file's header rather than hidden.
#
#   usage: sj-catalogue.sh [--no-pull] [outfile]   # default <data>/logs/CATALOGUE.md; "-" = stdout
set -uo pipefail

# App root. `cd -P` resolves symlinked path components physically — the hooks call this script
# through ~/.claude/hooks, which is itself a symlink into the app repo, so a logical `cd` would
# apply ".." to the link path and miss bin/lib.sh entirely. Not `readlink -f`: that's GNU-only
# (see the portability shims at the top of bin/lib.sh, and AGENTS.md).
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh"; sj_load_config

pull=1
case "${1:-}" in --no-pull) pull=0; shift ;; esac

DATA="$(sj_data)" || exit 1
[ -d "$DATA/logs" ] || exit 0

out="${1:-$DATA/logs/CATALOGUE.md}"

# ---- freshen the logs ------------------------------------------------------------------------
# --ff-only can't clobber local work: on a dirty or diverged tree it simply no-ops, and the next
# SessionEnd's push/rebase reconciles. `synced` becomes a line in the rendered header so the file
# always states how current it actually is.
synced="not a git repo — logs are local only"
if [ -d "$DATA/.git" ]; then
  if [ "$pull" = 0 ]; then
    synced="pulled by the caller"
  elif ( cd "$DATA" && sj_timeout 15 git pull --ff-only -q 2>/dev/null ); then
    synced="pulled $(date '+%Y-%m-%d %H:%M')"
  else
    behind="$( cd "$DATA" && git rev-list --count HEAD..@'{u}' 2>/dev/null )"
    if [ -n "${behind:-}" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
      synced="⚠ pull failed — $behind commit(s) behind origin, so other machines' newest chats are MISSING"
    else
      synced="⚠ pull failed or skipped $(date '+%Y-%m-%d %H:%M') — may be missing other machines' newest chats"
    fi
  fi
fi

tmp="$(mktemp)" || exit 1
trap 'rm -f "$tmp"' EXIT

# ---- parse every host's log into TSV, newest first -------------------------------------------
# Line shape (fields after `session=` are additive — older lines simply have fewer):
#   2026-07-15 22:36 | henpi | /path/to/proj | "topic" | session=<uuid> | harness=h | model=m | …
# Splitting on ` | ` is safe and matches the other readers (sj_log_catalogue in bin/lib.sh):
# log-session.sh strips `"` and `|` out of the topic before writing it for exactly this reason.
# `sort -r` on a leading `YYYY-MM-DD HH:MM` is a correct reverse-chronological sort, lexically.
awk -F' *\\| *' -v OFS='\t' '
  function human(b) {
    if (b == "" || b+0 <= 0) return ""
    if (b+0 >= 1048576) return sprintf("%.1fM", b/1048576)
    if (b+0 >= 1024)    return sprintf("%dK", b/1024)
    return b "B"
  }
  {
    sid = ""; harness = ""; model = ""; turns = ""; size = ""
    for (i = 5; i <= NF; i++) {
      if      ($i ~ /^session=/) sid     = substr($i, 9)
      else if ($i ~ /^harness=/) harness = substr($i, 9)
      else if ($i ~ /^model=/)   model   = substr($i, 7)
      else if ($i ~ /^turns=/)   turns   = substr($i, 7)
      else if ($i ~ /^size=/)    size    = substr($i, 6)
    }
    if (sid == "") next                       # not a session line (README prose, blank, …)

    topic = $4; gsub(/^"|"$/, "", topic)
    if (topic == "(no text)") topic = ""      # never summarized — blank beats a fake topic

    cwd = $3; sub(/\/+$/, "", cwd)
    project = cwd; sub(/^.*\//, "", project)
    if (project == "") project = "/"

    print $1, $2, project, harness, model, turns, human(size), substr(sid, 1, 8), topic
  }
' "$DATA"/logs/*.log 2>/dev/null | sort -r > "$tmp"

rows="$(wc -l < "$tmp" | tr -d ' ')"
hosts="$(cut -f2 "$tmp" | sort -u | tr '\n' ' ' | sed 's/ $//')"
named="$(awk -F'\t' '$9 != ""' "$tmp" | wc -l | tr -d ' ')"

# ---- render ----------------------------------------------------------------------------------
# Two passes over $tmp: measure each column, then pad to it. Aligned pipes cost a few bytes and
# make the raw file readable without a Markdown renderer — the entire point of this artifact.
render() {
  cat <<EOF
# Chat catalogue

Every session scrubjay has logged, from every machine — newest first.
**$rows sessions** across: $hosts. ($named have a topic; see the note below.)

**Sync:** $synced

Generated by \`bin/sj-catalogue.sh\` from \`logs/*.log\` — do not edit, and do not commit
(it is derived, and regenerates on every SessionStart / SessionEnd).

Another machine's chats land here once its \`SessionEnd\` has pushed *and* this one has pulled.
Re-run \`bin/sj-catalogue.sh\` (it pulls first) or \`/sjsync\` to refresh without waiting for
your next session to start.

To pull one into a chat, use its **Session** id: \`/sjget <id>\`, or \`/sjresume <id>\` to
continue it on this machine. Plain \`grep\` works fine here too.

EOF

  awk -F'\t' '
    NR == FNR {
      for (i = 1; i <= 9; i++) if (length($i) > w[i]) w[i] = length($i)
      next
    }
    FNR == 1 {
      split("Date\tHost\tProject\tHarness\tModel\tTurns\tSize\tSession\tTopic", h, "\t")
      for (i = 1; i <= 9; i++) if (length(h[i]) > w[i]) w[i] = length(h[i])
      line = ""; sep = ""
      for (i = 1; i <= 9; i++) {
        line = line "| " sprintf("%-*s", w[i], h[i]) " "
        sep  = sep  "|"  sprintf("%*s", w[i] + 2, "")
      }
      gsub(/ /, "-", sep)
      print line "|"; print sep "|"
    }
    {
      line = ""
      for (i = 1; i <= 9; i++) line = line "| " sprintf("%-*s", w[i], $i) " "
      print line "|"
    }
  ' "$tmp" "$tmp"

  cat <<'EOF'

---

**Why some topics are blank.** The one-sentence topic is written by the model, and only the
`/sjlog` path has a model in the loop. A session that just ends (SessionEnd fires with no model
running) falls back to its first user prompt, and logs `(no text)` when it cannot find one —
which is most of them. Those rows are kept here, topic blank, because the session is still real
and still resumable by id. `/sjbrowse` hides them; this file does not.

**Why `Model` / `Turns` / `Size` are blank on older rows.** Those fields were added on
2026-07-15; `Harness` on 2026-07-14. Lines written before a field existed simply lack it.
EOF
}

if [ "$out" = "-" ]; then
  render
else
  render > "$out" || exit 1
  printf 'scrubjay: catalogue -> %s (%s sessions)\n' "$out" "$rows"
fi
