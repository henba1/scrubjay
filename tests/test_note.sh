#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/sj-note.sh — the /sjnote write path, plus the lib.sh helpers it shares with the plan/readable
# namers.
#
# The property under test is mostly about WHERE things land. A note that lands one level too high
# stops being a note and becomes a memory: it gets picked up by sjmcp's _iter_memories, and — much
# worse — it sits in a directory whose MEMORY.md is loaded into every future session. The whole
# point of the feature is that a two-page document costs nothing until it is asked for, so
# "notes/ is a subdirectory" and "MEMORY.md gains exactly one line, ever" are the two assertions
# that actually matter here.
#
# Hermetic: sj_sandbox pins SCRUBJAY_MEMORY inside $SANDBOX and SCRUBJAY_MEMORY_REMOTE to "", so
# nothing here can reach a real NAS. The publish path is covered by tests/test_memory.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

. "$APP/bin/lib.sh"

MEM="$SCRUBJAY_MEMORY"
PROJ="-test-project"
note() { bash "$APP/bin/sj-note.sh" --project "$PROJ" "$@"; }
notes_dir="$MEM/$PROJ/notes"

# ── the shared namers ──────────────────────────────────────────────────────────────────────────
# sj_slugify and sj_unique_path were extracted from sj_readable_relpath and sj_normalize_plans,
# which each carried their own copy. Both callers now depend on these, so a regression here breaks
# transcript and plan naming too — not just notes.
section "sj_slugify / sj_unique_path"
assert_eq "lowercases, collapses punctuation, trims dashes" \
  "fsl-impact-on-document-b" "$(sj_slugify '  FSL impact on Document B!! ')"
assert_eq "truncates without leaving a dangling dash" \
  "one-two" "$(sj_slugify 'one two three' 8)"
assert_eq "empty in, empty out" "" "$(sj_slugify '   ')"
# The slug can never contain '__', which is what lets sjmcp parse <topic>__<sid8> off a filename.
assert_eq "underscores do not survive slugging" \
  "a-b" "$(sj_slugify 'a__b')"
mkdir -p "$SANDBOX/uniq"; : > "$SANDBOX/uniq/x.md"
assert_eq "first free name is the bare stem" \
  "y.md" "$(basename "$(sj_unique_path "$SANDBOX/uniq" y md)")"
assert_eq "a clash gets a -2 suffix" \
  "x-2.md" "$(basename "$(sj_unique_path "$SANDBOX/uniq" x md)")"

# ── where a note lands ─────────────────────────────────────────────────────────────────────────
section "a note lands in <project>/notes/, not beside the memories"
out="$(printf '# FSL impact on Document B\n\nbody text\n' | note 2>&1)"
f="$(ls "$notes_dir"/*.md 2>/dev/null | head -1)"
check "the notes/ subdirectory was created" test -d "$notes_dir"
assert_contains "the file is dated and slugged from the heading" \
  "$(basename "${f:-none}")" "_fsl-impact-on-document-b"
assert_contains "the run reports the path it wrote" "$out" "notes/"
assert_eq "the body is stored verbatim" "body text" "$(sed -n 3p "${f:-/dev/null}")"
# The load-bearing one: a stray note at <project>/*.md would be listed as a memory by sjmcp AND
# would sit in the auto-loaded directory.
assert_eq "nothing was written next to the memories" \
  "0" "$(ls "$MEM/$PROJ"/*.md 2>/dev/null | grep -cv 'MEMORY.md$')"

section "an explicit topic wins over the heading"
printf '# ignored heading\n' | note --topic "Anwalt Briefing / Nutzungsvertrag" >/dev/null 2>&1
check "the given topic is used" ls "$notes_dir"/*_anwalt-briefing-nutzungsvertrag.md

section "same day, same topic does not overwrite"
printf 'second\n' | note --topic "collide" >/dev/null 2>&1
printf 'third\n'  | note --topic "collide" >/dev/null 2>&1
assert_eq "the second note got a -2 suffix" \
  "2" "$(ls "$notes_dir"/*collide*.md 2>/dev/null | wc -l | tr -d ' ')"

# ── the index line ─────────────────────────────────────────────────────────────────────────────
# MEMORY.md is loaded into every session under a 200-line budget. An index that grew per note would
# spend exactly the context this feature exists to save, so the line is rewritten in place.
section "MEMORY.md gains ONE line, rewritten in place"
idx="$MEM/$PROJ/MEMORY.md"
assert_file "MEMORY.md exists" "$idx"
assert_eq "exactly one notes/ pointer, however many notes there are" \
  "1" "$(grep -c '^- notes/ ' "$idx" | tr -d ' ')"
assert_contains "it carries the live count" "$(grep '^- notes/ ' "$idx")" "4 documents"
assert_contains "and says how to reach them" "$(grep '^- notes/ ' "$idx")" "/sjrecall"

section "an existing MEMORY.md is preserved, not clobbered"
printf '# Memory index\n\n- [A real memory](a-real-memory.md) — hook\n' > "$idx"
printf 'body\n' | note --topic "later note" >/dev/null 2>&1
assert_contains "the pre-existing memory line survived" "$(cat "$idx")" "[A real memory]"
assert_eq "still exactly one notes/ pointer" \
  "1" "$(grep -c '^- notes/ ' "$idx" | tr -d ' ')"

# ── promotion ──────────────────────────────────────────────────────────────────────────────────
# The originating case: an artefact already written to the session scratchpad, which has to be
# rescued without being rewritten.
section "--from promotes an existing file without altering it"
src="$SANDBOX/scratch-briefing.md"
printf '# Briefing\n\nverbatim content\n' > "$src"
printf 'x' | note --from "$src" >/dev/null 2>&1
p="$(ls "$notes_dir"/*_briefing.md 2>/dev/null | head -1)"
assert_file "the promoted note exists" "${p:-/nonexistent}"
assert_eq "content is byte-identical to the source" \
  "" "$(diff "$src" "${p:-/dev/null}" 2>&1)"
assert_file "the source file is left in place (it may still be open)" "$src"

# ── degradation ────────────────────────────────────────────────────────────────────────────────
section "bad input fails loudly, a missing remote does not"
check_fails "an empty body is refused" bash -c "printf '' | bash '$APP/bin/sj-note.sh' --project '$PROJ'"
check_fails "--from a missing file is refused" \
  bash "$APP/bin/sj-note.sh" --project "$PROJ" --from "$SANDBOX/nope.md"
check_fails "an unknown flag is refused" \
  bash -c "printf 'x' | bash '$APP/bin/sj-note.sh' --project '$PROJ' --bogus"
# SCRUBJAY_MEMORY_REMOTE is "" in the sandbox: memory sync is simply off on this host. That must
# not lose the note — it is committed locally and the next sync publishes it.
before="$(ls "$notes_dir"/*.md | wc -l | tr -d ' ')"
out="$(printf 'body\n' | note --topic "no remote" 2>&1)"
assert_eq "the note is still written with no memory remote" \
  "$((before + 1))" "$(ls "$notes_dir"/*.md | wc -l | tr -d ' ')"
assert_contains "and the run says sync is off rather than claiming success" "$out" "memory sync is off"

# ── the sjmcp contract ─────────────────────────────────────────────────────────────────────────
# _iter_memories globs <project>/*.md non-recursively; _iter_notes walks <project>/notes/. If that
# ever changed, every note would be listed twice — once correctly and once as a "memory".
section "sjmcp types notes as notes, and only once"
if need_cmd uv "sjmcp enumerates the notes"; then
  # A clean memory tree, so the counts below are exact rather than "whatever the rest of this
  # file happened to write". One memory, and one note of each filename shape: with a session
  # backlink and without (a note written outside a session, or dropped in by hand on the NAS).
  probe="$SANDBOX/probe-memory"; mkdir -p "$probe/-p/notes"
  echo "a fact" > "$probe/-p/a-real-memory.md"
  printf '# parsed\nbody\n' > "$probe/-p/notes/2026-08-05_with-backlink__abcd1234.md"
  printf '# plain\nbody\n'  > "$probe/-p/notes/2026-08-04_no-backlink.md"
  json="$(SCRUBJAY_LOCAL_CHATS="" SCRUBJAY_MEMORY="$probe" SCRUBJAY_DATA="" \
          uv run --script "$APP/mcp/sjmcp_server.py" --selftest 2>/dev/null)"
  assert_contains "both notes are counted, and as notes" "$json" '"note": 2'
  assert_contains "the memory beside them is still a memory" "$json" '"memory": 1'
  assert_contains "a note lists with type=note" "$json" '"type": "note"'
  assert_contains "the date is parsed off the filename" "$json" '"date": "2026-08-05"'
  assert_contains "the topic is un-slugged for display" "$json" '"topic": "with backlink"'
  assert_contains "the session backlink survives" "$json" '"sid": "abcd1234"'
  # The no-backlink shape must degrade to <date>_<topic>, not fall through to a bare stem.
  assert_contains "a note without a backlink still parses its date" "$json" '"date": "2026-08-04"'
  assert_contains "and its topic" "$json" '"topic": "no backlink"'
fi

finish
