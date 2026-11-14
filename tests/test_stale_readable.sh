#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# One readable per session, when the TOPIC in its name moved.
#
# A session that opens with a slash command (`/clear`, `/resume`, a skill) has no prose prompt yet,
# so sj_session_topic falls back to the command and the first publish files it as
# `<date>_clear__<sid8>.md`. Once a prose prompt exists, prose wins (by design, see test_topics.sh)
# and every later publish writes `<date>_<real-topic>__<sid8>.md`. The relay is write-only, so the
# first file is never removed: a truncated copy under the same handle. Seen for real on 2026-11-14 —
# `sj_get <sid8>` returned the 2-turn `clear` copy of a 70-turn session, which read as data loss.
#
# Identity is host + handle + the rendering's first line (`# <first user prompt>`): a session's
# first turn never changes as it grows, and two sessions sharing an 8-char prefix will not share it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

ARCHIVE="$SCRUBJAY_LOCAL_CHATS"
RD="$ARCHIVE/hostpi/readable/proj"; mkdir -p "$RD"

stale="$RD/2026-11-13_clear__abcd1234.md"
current="$RD/2026-11-13_yes-go-ahead__abcd1234.md"
collide="$RD/2026-11-13_other-session__abcd1234.md"   # same handle, a DIFFERENT session

printf '# The user wants to find a past conversation\n\n_2 turns_\n\n## User\n\nstale only\n' > "$stale"
touch -t 202611131600 "$stale"
printf '# The user wants to find a past conversation\n\n_70 turns_\n\n## User\n\nthe whole session, needle-current\n' > "$current"
touch -t 202611141100 "$current"
printf '# a completely different first prompt\n\n_3 turns_\n\n## User\n\nneedle-current too\n' > "$collide"
touch -t 202611120900 "$collide"

if need_cmd python3 "sjmcp: one readable per session"; then
  OUT="$SANDBOX/probe.json"
  SJ_SERVER="$APP/mcp/sjmcp_server.py" python3 - "$OUT" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("sjmcp_server", os.environ["SJ_SERVER"])
m = importlib.util.module_from_spec(spec); sys.modules["sjmcp_server"] = m; spec.loader.exec_module(m)
r = m.roots()
got = m.core_get("abcd1234")
listed = [a["path"] for a in m.core_list(type="transcript", limit=0, max_chars=0)["items"]]
rec = [x["path"] for x in m.core_recall("needle-current")["results"]]
rec_stale = [x["path"] for x in m.core_recall("stale only")["results"]]
json.dump({"get": got.get("path", ""), "listed": listed, "recall": rec, "recall_stale": rec_stale},
          open(sys.argv[1], "w"))
PY
  j() { jq -r "$1" "$OUT"; }

  section "sj_get by handle returns the current copy, not the stale one"
  assert_eq "resolves to the newest copy of the session" "$current" "$(j .get)"

  section "sj_list shows the session once"
  assert_eq "the stale copy is not listed" "0" "$(j "[.listed[] | select(. == \"$stale\")] | length")"
  assert_eq "the current copy is listed" "1" "$(j "[.listed[] | select(. == \"$current\")] | length")"
  assert_eq "a different session sharing the handle is still listed" "1" \
    "$(j "[.listed[] | select(. == \"$collide\")] | length")"

  section "sj_recall never surfaces the stale copy"
  assert_eq "current copy found" "1" "$(j "[.recall[] | select(. == \"$current\")] | length")"
  assert_eq "the colliding session is found too" "1" "$(j "[.recall[] | select(. == \"$collide\")] | length")"
  assert_eq "a term only the stale copy holds finds nothing" "0" "$(j '.recall_stale | length')"
fi

section "backfill prunes a copy left by topic drift, and nothing else"
# The real transcript, so backfill renders it: its readable title is the fixture's first prompt.
sid="11111111-2222-4333-8444-555555555555"
mkdir -p "$ARCHIVE/testhost/-home-user-widget-api"
cp "$FIXTURES/claude-session.jsonl" "$ARCHIVE/testhost/-home-user-widget-api/$sid.jsonl"
good="$(sj_readable_relpath "$FIXTURES/claude-session.jsonl" "$sid")"
title="$(bash "$APP/bin/render-transcript.sh" "$FIXTURES/claude-session.jsonl" | head -n 1)"
drift="$ARCHIVE/testhost/readable/widget-api/$(basename "$good" | cut -d_ -f1)_clear__11111111.md"
mkdir -p "$(dirname "$drift")"
printf '%s\n\n_1 turns_\n' "$title" > "$drift"                      # same title, other topic → stale
other="$ARCHIVE/testhost/readable/widget-api/2026-03-09_unrelated__11111111.md"
printf '# some other session entirely\n' > "$other"                 # same handle, other title → keep
foreign="$ARCHIVE/otherhost/readable/widget-api/$(basename "$drift")"
mkdir -p "$(dirname "$foreign")"; cp "$drift" "$foreign"            # other host → never touched

bash "$APP/bin/backfill-readable.sh" "$ARCHIVE" >/dev/null 2>&1
check "the canonical copy is rendered" test -s "$ARCHIVE/testhost/readable/$good.md"
check_fails "the topic-drift copy is gone" test -e "$drift"
check "a different session under the same handle survives" test -e "$other"
check "another host's archive is not touched" test -e "$foreign"

finish
