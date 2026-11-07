#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The moves ledger (bin/sj-moves.sh): where a path went after a session recorded it. What must hold:
# the newest word on a path wins, a move carries on from an earlier one, moving back cancels out,
# a resumed session is told exactly the moves its history touches, and a transcript is never edited.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

M="$APP/bin/sj-moves.sh"
# Lines written straight in where order matters: two `add`s can land in the same second.
led() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$SCRUBJAY_DATA/moves/testhost.tsv"; }
reset() { rm -rf "$SCRUBJAY_DATA/moves"; mkdir -p "$SCRUBJAY_DATA/moves"; }

section "add, undo, list"
assert_eq "no ledger: nothing in force" "" "$(bash "$M" list)"
bash "$M" add testhost /home/user/old/ /home/user/new
assert_eq "recorded, the trailing slash dropped" "$(printf 'testhost\t/home/user/old\t/home/user/new')" "$(bash "$M" list)"
assert_file "in this machine's own file" "$SCRUBJAY_DATA/moves/testhost.tsv"
bash "$M" undo testhost /home/user/old
assert_eq "undone" "" "$(bash "$M" list)"

section "what add refuses"
assert_contains "a relative path" "$(bash "$M" add testhost old /new 2>&1)" "not an absolute path"
assert_contains "the root" "$(bash "$M" add testhost / /new 2>&1)" "root folder"
assert_contains "no change" "$(bash "$M" add testhost /a /a/ 2>&1)" "same path"
assert_contains "a tab" "$(bash "$M" add testhost "$(printf '/a\tb')" /new 2>&1)" "tab or line break"
check_fails "and says so by its exit code" bash "$M" add testhost old /new

section "chains, and moving back"
reset; led 1 testhost /a /b; led 2 testhost /b /c
assert_contains "a → b then b → c lists a → c" "$(bash "$M" list)" "$(printf 'testhost\t/a\t/c')"
reset; led 1 testhost /a /b/sub; led 2 testhost /b /c
assert_contains "a move of a folder above it carries too" "$(bash "$M" list)" "$(printf 'testhost\t/a\t/c/sub')"
reset; led 1 testhost /a /b; led 2 testhost /b /a
assert_eq "there and back: a stands, nothing to rewrite from it" "$(printf 'testhost\t/b\t/a')" "$(bash "$M" list)"
reset; led 1 testhost /b /c; led 2 testhost /a /b
assert_contains "an older move is not carried on from" "$(bash "$M" list)" "$(printf 'testhost\t/a\t/b')"
reset; led 1 testhost /a /b; led 2 laptop /b /c
assert_contains "another machine's folder of the same name is another folder" "$(bash "$M" list)" "$(printf 'testhost\t/a\t/b')"

section "resolve"
reset; led 1 testhost /home/user/code /home/user/src; led 2 testhost /home/user/code/api /srv/api
assert_eq "under a moved folder" /home/user/src/x/y "$(bash "$M" resolve testhost /home/user/code/x/y)"
assert_eq "the longest wins" /srv/api/z "$(bash "$M" resolve testhost /home/user/code/api/z)"
assert_eq "a name that only starts the same" /home/user/codex "$(bash "$M" resolve testhost /home/user/codex)"
assert_eq "another machine's" /home/user/code/x "$(bash "$M" resolve laptop /home/user/code/x)"

section "a resumed session is told, from turn one; the transcript is left alone"
reset; led 1 testhost /home/user/widget-api /home/user/widget; led 2 testhost /home/user/unrelated /home/user/other
t="$SANDBOX/s.jsonl"; cp "$FIXTURES/claude-session.jsonl" "$t"; before="$(cksum < "$t")"
hook() { printf '{"session_id":"x","source":"%s","transcript_path":"%s"}' "$1" "$t" | \
  SCRUBJAY_SYNC_NOPULL=1 SCRUBJAY_NORECONCILE=1 bash "$APP/hooks/sync-session.sh" 2>/dev/null; }
out="$(hook resume)"
assert_contains "names the move its history touches" "$out" "/home/user/widget-api -> /home/user/widget"
case "$out" in *unrelated*) _no "says nothing of one it does not" "$out" ;; *) _ok "says nothing of one it does not" ;; esac
case "$(hook startup)" in *"-> /home/user/widget"*) _no "a new session hears nothing" ;; *) _ok "a new session hears nothing" ;; esac
assert_eq "the transcript is untouched" "$before" "$(cksum < "$t")"

section "a hand-off on this machine rewrites with the ledger"
A="$SCRUBJAY_LOCAL_CHATS/testhost/-home-user-widget-api"; mkdir -p "$A"
SID=11111111-2222-4333-8444-555555555555
sed 's#/home/user/widget-api#/home/user/gone-api#g' "$FIXTURES/claude-session.jsonl" > "$A/$SID.jsonl"
printf '%s\n' '{"type":"user","sessionId":"'$SID'","message":{"role":"user","content":"see /home/user/notes/plan.md"}}' >> "$A/$SID.jsonl"
d="$SANDBOX/new-home"; mkdir -p "$d"; dreal="$(cd -P "$d" && pwd)"
reset; led 1 testhost /home/user/notes /home/user/docs
bash "$APP/bin/sj-resume.sh" "$SID" --into "$d" >/dev/null 2>&1
staged="$(find "$CLAUDE_CONFIG_DIR/projects" -name "$SID.jsonl" | head -1)"
assert_contains "a path outside the session's folder follows the ledger" "$(cat "$staged")" "/home/user/docs/plan.md"
assert_contains "and the folder itself goes where it was staged" "$(cat "$staged")" "$dreal"
assert_contains "the archive keeps what was said" "$(cat "$A/$SID.jsonl")" "/home/user/notes/plan.md"

finish
