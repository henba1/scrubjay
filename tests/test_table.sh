#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# sj-table.sh queries the rendered catalogue: filter rows, then slice them. The contract worth
# pinning is that filters compose with slices (filter FIRST, slice the result — "the newest 20
# opencode sessions" is one question, not two), that a slice still arrives as a readable table,
# and that printing nothing is the default because ~600 rows in a chat costs more than the MCP
# round-trip the catalogue exists to avoid.
#
# The end-to-end half runs against a real catalogue rendered by sj-catalogue.sh from a fixture
# log, so the two scripts are proven to agree on the row shape rather than each asserting its own.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

export SCRUBJAY_TABLE_LIB=1; . "$APP/bin/sj-table.sh"; unset SCRUBJAY_TABLE_LIB

section "pandas-style slice parsing"
assert_eq "[2:5] is start 2, count 3"      "2 3" "$(sjt_parse_slice '[2:5]' 10)"
assert_eq "[0:1] is the first row"         "0 1" "$(sjt_parse_slice '[0:1]' 10)"
assert_eq "[3:] runs to the end"           "3 7" "$(sjt_parse_slice '[3:]' 10)"
assert_eq "[:4] runs from the start"       "0 4" "$(sjt_parse_slice '[:4]' 10)"
assert_eq "an inverted range is empty, not negative" "0 0" "$(sjt_parse_slice '[9:2]' 10)"
check_fails "a non-slice argument is refused" sjt_parse_slice 'head=3' 10
check_fails "a non-numeric bound is refused" sjt_parse_slice '[a:b]' 10

# ---- a real catalogue, rendered by the real renderer -----------------------------------------
LOGS="$SCRUBJAY_DATA/logs"; mkdir -p "$LOGS"
{
  echo '2026-08-02 10:00 | henpi | /p/alpha | "alpha work" | session=aaaaaaaa-1111-4111-8111-111111111111 | harness=claude | model=opus | turns=10 | size=2048'
  echo '2026-08-01 09:00 | henpi | /p/beta | "beta work" | session=bbbbbbbb-1111-4111-8111-111111111111 | harness=opencode | model=gpt | turns=5 | size=1024'
  echo '2026-07-15 08:00 | laptop | /p/alpha | "gamma work" | session=cccccccc-1111-4111-8111-111111111111 | harness=claude | model=opus | turns=3 | size=512'
  echo '2026-07-01 07:00 | laptop | /p/gamma | "(no text)" | session=dddddddd-1111-4111-8111-111111111111 | harness=codex | model=gpt | turns=1 | size=256'
  echo '2026-06-20 06:00 | snellius | /p/delta | "delta work" | session=eeeeeeee-1111-4111-8111-111111111111'
} > "$LOGS/testhost.log"

table() { bash "$APP/bin/sj-table.sh" --no-pull "$@" 2>/dev/null; }
datarows() { table "$@" | grep -c '^| 20'; }

section "the catalogue is generated on demand when it is missing"
assert_no_file "no catalogue before the first query" "$LOGS/CATALOGUE.md"
out="$(table)"
assert_file "querying rendered one" "$LOGS/CATALOGUE.md"
assert_contains "summary counts every session" "$out" "5 sessions"

section "printing nothing is the default — rows are opt-in"
assert_eq "a bare call emits no table rows" "0" "$(datarows)"
assert_contains "but it says how to get them" "$(table)" "add head=N, tail=N, [a:b], all, or a filter"

section "slices: head / tail / [a:b], newest first"
assert_eq "head=2 gives two rows"  "2" "$(datarows head=2)"
assert_eq "all gives every row"    "5" "$(datarows all)"
assert_contains "head=1 is the NEWEST session" "$(table head=1)" "alpha work"
assert_contains "tail=1 is the OLDEST session" "$(table tail=1)" "delta work"
assert_eq "[1:3] gives two rows"   "2" "$(datarows '[1:3]')"
assert_contains "[1:3] starts at the second-newest" "$(table '[1:3]')" "beta work"
assert_eq "head beyond the end is clamped, not an error" "5" "$(datarows head=99)"

section "a slice still arrives as a readable table"
assert_contains "the header row is reprinted" "$(table head=1)" "| Date "
assert_contains "and its separator rule" "$(table head=1)" "|---"

section "filters"
assert_eq "harness=opencode matches one" "1" "$(datarows harness=opencode)"
assert_eq "harness=claude matches two"   "2" "$(datarows harness=claude)"
assert_eq "host=laptop matches two"      "2" "$(datarows host=laptop)"
assert_eq "project= is a substring match" "2" "$(datarows project=alpha)"
assert_eq "since= is inclusive of its day" "4" "$(datarows since=2026-07-01)"
assert_eq "until= trims the newest"        "3" "$(datarows until=2026-07-15)"
assert_eq "topic= searches the topic text" "1" "$(datarows topic=gamma)"
assert_contains "no match says so plainly" "$(table harness=nope)" "no sessions match"

section "a filter prints its rows unasked — but caps, and says it capped"
assert_contains "an unfiltered call stays a summary" "$(table)" "sessions in the catalogue"
assert_eq "a filtered call prints rows without needing a slice" "2" "$(datarows harness=claude)"
assert_eq "the cap bounds a broad filter" "2" "$(SCRUBJAY_TABLE_CAP=2 datarows since=2026-01-01)"
assert_contains "and the truncation is stated, not silent" \
  "$(SCRUBJAY_TABLE_CAP=2 table since=2026-01-01)" "showing the newest 2 of 5 matches"

section "filters compose with slices — filter FIRST, then slice"
assert_eq "harness=claude head=1 gives one row" "1" "$(datarows harness=claude head=1)"
assert_contains "and it is the newest CLAUDE session, not the newest session" \
  "$(table harness=claude head=1)" "alpha work"
assert_contains "tail of a filtered set is the oldest MATCH" \
  "$(table harness=claude tail=1)" "gamma work"

section "a session that never got a topic is still a row (sj_list drops these; the table does not)"
assert_contains "the topic-less session appears by id" "$(table all)" "dddddddd"
assert_eq "and it counts toward the total" "5" "$(datarows all)"

section "bad input fails loudly rather than printing the wrong rows"
check_fails "head= without a number is refused" bash "$APP/bin/sj-table.sh" --no-pull head=x
check_fails "an unknown argument is refused"    bash "$APP/bin/sj-table.sh" --no-pull nonsense=1

finish
