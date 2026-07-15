#!/usr/bin/env bash
# The write path end to end: bin/ship-transcript.sh relaying a session into the archive, for both
# Claude and opencode, via the harness-blind seam. This is what SessionEnd runs, so it is the thing
# most worth having a regression test on.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

ARCHIVE="$SCRUBJAY_LOCAL_CHATS"

section "claude: a session lands in the archive"
sid="11111111-2222-4333-8444-555555555555"
slug="-home-user-widget-api"
SCRUBJAY_HARNESS=claude bash "$APP/bin/ship-transcript.sh" \
  "$FIXTURES/claude-session.jsonl" "$slug" "$sid" testhost /home/user/widget-api >/dev/null 2>&1

assert_file "transcript archived as .jsonl" "$ARCHIVE/testhost/$slug/$sid.jsonl"
readable="$(find "$ARCHIVE/testhost/readable" -name "*$( printf %.8s "$sid" )*.md" 2>/dev/null | head -1)"
assert_file "a readable rendering was produced" "$readable"
assert_contains "readable is filed under the project" "$readable" "/readable/widget-api/"

section "opencode: a session lands in the archive with a .json extension"
osid="ses_66a71b6f4ffeq796jvvOpJQ04m"
SCRUBJAY_HARNESS=opencode bash "$APP/bin/ship-transcript.sh" \
  "$FIXTURES/opencode-export.json" "-home-user-widget-api" "$osid" testhost /home/user/widget-api >/dev/null 2>&1

assert_file "opencode transcript archived as .json" "$ARCHIVE/testhost/-home-user-widget-api/$osid.json"
oread="$(find "$ARCHIVE/testhost/readable" -name '*66a71b6f*.md' 2>/dev/null | head -1)"
assert_file "opencode readable was produced" "$oread"

section "the shipped tree is what the read side expects"
# sj_archive_resolve is what /sjresume uses to find a session; prove ship + resolve agree, by both
# the full id and the 8-char handle, across both extensions.
. "$APP/bin/lib.sh"
export -f sj_archive_resolve   # the checks below pipe through grep, so they run in a bash -c subshell
check "resolve claude session by handle" bash -c 'sj_archive_resolve "$1" 11111111 | grep -q .jsonl' _ "$ARCHIVE"
check "resolve opencode session by handle" bash -c 'sj_archive_resolve "$1" 66a71b6f | grep -q .json' _ "$ARCHIVE"

section "a re-ship overwrites in place (idempotent)"
before="$(find "$ARCHIVE" -type f | sort)"
SCRUBJAY_HARNESS=claude bash "$APP/bin/ship-transcript.sh" \
  "$FIXTURES/claude-session.jsonl" "$slug" "$sid" testhost /home/user/widget-api >/dev/null 2>&1
after="$(find "$ARCHIVE" -type f | sort)"
assert_eq "re-shipping adds no new files" "$before" "$after"

finish
