#!/usr/bin/env bash
# Cross-machine hand-off (bin/sj-resume.sh). The regression that matters here is the one that was a
# real bug: a session must be read using the harness that PRODUCED it, and a cross-harness hand-off
# must carry the conversation over rather than stage a file the target cannot load.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

ARCHIVE="$SCRUBJAY_LOCAL_CHATS"

# Seed the archive as if another machine ('otherhost') had shipped these sessions.
seed() {  # seed <relpath> <fixture>
  mkdir -p "$ARCHIVE/$(dirname "$1")"; cp "$2" "$ARCHIVE/$1"
}
seed "otherhost/-home-user-widget-api/11111111-2222-4333-8444-555555555555.jsonl" "$FIXTURES/claude-session.jsonl"
seed "otherhost/-home-user-widget-api/ses_66a71b6f4ffeq796jvvOpJQ04m.json"        "$FIXTURES/opencode-export.json"

work="$SANDBOX/work"; mkdir -p "$work"

section "same-harness: claude session, resumed as claude, stages natively"
out="$(SCRUBJAY_HARNESS=claude bash "$APP/bin/sj-resume.sh" 11111111 --into "$work" --no-import 2>&1)"
assert_contains "reports the source harness" "$out" "source: claude"
assert_contains "rewrites the foreign path to the local cwd" "$out" "$work"
staged="$(find "$CLAUDE_CONFIG_DIR/projects" -name '11111111*.jsonl' 2>/dev/null | head -1)"
assert_file "the transcript is staged where claude --resume finds it" "$staged"

section "cross-harness: claude session, resumed from opencode, carries over (does NOT fake import)"
out="$(SCRUBJAY_HARNESS=opencode bash "$APP/bin/sj-resume.sh" 11111111 --into "$work" 2>&1)"
assert_contains "names both harnesses" "$out" "source: claude"
assert_contains "says opencode cannot resume it natively" "$out" "cannot resume it natively"
assert_contains "hands over via a context command" "$out" "opencode run"
# The critical bug: it must NOT stage a claude .jsonl as an opencode import.
inbox="$HOME/.local/share/scrubjay/inbox/opencode"
assert_no_file "no bogus .json import was staged" "$inbox/11111111-2222-4333-8444-555555555555.json"
primer="$inbox/11111111-2222-4333-8444-555555555555.md"
assert_file "a readable primer was rendered instead" "$primer"
assert_contains "primer is real rendered content" "$(cat "$primer" 2>/dev/null)" "retry backoff"

section "an unknown handle fails cleanly (does not stage garbage)"
check_fails "resolving a nonexistent session" \
  bash -c 'SCRUBJAY_HARNESS=claude bash "$1/bin/sj-resume.sh" deadbeef --into "$2" >/dev/null 2>&1' _ "$APP" "$work"

finish
