#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/sj-pick.py, the session picker behind `sj`. What must hold: it opens on the project of the
# folder it starts in (the git repository, a worktree of it included; another machine's sessions by
# the repository's name), live ones first, untitled ones left out; Tab's --all shows every project;
# and Enter does what `sj resume` would, never a second live copy: switch or attach to a tmux session
# here, refuse one running outside tmux, `sj resume` the rest, from the popup in a new tmux session.
# The panel's text comes from the transcript: the first and last real prompt, the reply's prose.
# The rows are a file (SJ_PICK_ROWS): `sj rows` itself is tests/test_sj.sh's.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
need_cmd python3 "the picker" || { finish; exit 0; }
need_cmd git "the picker" || { finish; exit 0; }

PICK="$APP/bin/sj-pick.py"
RAPP="$(cd -P "$APP" && pwd)"   # the picker names itself by its real path
unset TMUX TMUX_PANE
export SJ_KEEP_TMUX=sj-no-such-tmux SJ_PICK_ROWS="$SANDBOX/rows.tsv"

code="$SANDBOX/code"; mkdir -p "$code/widget" "$code/other"; code="$(cd -P "$code" && pwd)"
git -C "$code/widget" init -q
git -C "$code/widget" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$code/widget" worktree add -q -b feat "$code/widget-wt" 2>/dev/null
W="$code/widget" WT="$code/widget-wt" O="$code/other"
NOW="$(date +%s)"

A=aaaa0001-0000-4000-8000-000000000001   # working here, in tmux
B=bbbb0002-0000-4000-8000-000000000002   # idle here, in a worktree, outside tmux
C=cccc0003-0000-4000-8000-000000000003   # ended here, its transcript here
D=dddd0004-0000-4000-8000-000000000004   # idle on another host, same repository by name
E=eeee0005-0000-4000-8000-000000000005   # another project
F=ffff0006-0000-4000-8000-000000000006   # untitled
G=ses_opencode0007                       # an opencode session
H=99990008-0000-4000-8000-000000000008   # recorded on another host, not here
{
  printf 'L\there\ttesthost\t%s\tworking\t%s\tsj-claude-widget\t1\t%s\t101\n' "$A" "$((NOW - 10))" "$W"
  printf 'L\there\ttesthost\t%s\tidle\t%s\t-\t0\t%s\t4242\n' "$B" "$((NOW - 60))" "$WT"
  printf 'L\there\ttesthost\t%s\tended\t%s\t-\t0\t%s\t-\n' "$C" "$((NOW - 3600))" "$W"
  printf 'L\trelay\totherhost\t%s\tidle\t%s\t-\t0\t/home/u/widget\t-\n' "$D" "$((NOW - 7200))"
  printf 'C\t2026-11-01 10:00\ttesthost\t%s\t%s\tretry backoff fix\tclaude\t\n' "$C" "$W"
  printf 'C\t2026-11-01 09:00\ttesthost\t%s\t%s\tunrelated thing\tclaude\t\n' "$E" "$O"
  printf 'C\t2026-11-01 08:00\ttesthost\t%s\t%s\t(no text)\tclaude\t\n' "$F" "$W"
  printf 'C\t2026-10-01 08:00\ttesthost\t%s\t%s\tan opencode one\topencode\t\n' "$G" "$W"
  printf 'C\t2026-09-01 08:00\totherhost\t%s\t/home/u/widget\tfrom the laptop\tclaude\t\n' "$H"
} > "$SJ_PICK_ROWS"

mkdir -p "$CLAUDE_CONFIG_DIR/projects/-w"
{
  echo '{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}'
  echo '{"type":"user","message":{"content":"make the retries back off"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}'
  echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}'
  echo '{"type":"user","message":{"content":"<command-name>/sjlog</command-name><command-args>now</command-args>"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Published the session, and the backoff now doubles up to 30 s.\n```sh\nretry --max 30\n```"}]}}'
} > "$CLAUDE_CONFIG_DIR/projects/-w/$C.jsonl"

list() { (cd "$1" && shift && python3 "$PICK" --list "$@"); }
ids() { list "$@" | sed 1d | cut -c1-4 | tr '\n' ' '; }
plan() { (cd "$W" && python3 "$PICK" --plan "$@"); }

section "the list: this project, live first"
assert_eq "opens on the folder's repository" "# widget" "$(list "$W" | head -n 1)"
assert_eq "live here, live elsewhere, then the rest newest first; untitled and other projects left out" \
  "aaaa bbbb dddd cccc ses_ 9999 " "$(ids "$W")"
assert_eq "a worktree is the same project" "# widget" "$(list "$WT" | head -n 1)"
assert_eq "--all: every project" "aaaa bbbb dddd cccc eeee ses_ 9999 " "$(ids "$W" --all)"
assert_eq "--live: live ones only" "aaaa bbbb dddd " "$(ids "$W" --live)"
assert_eq "a folder with no sessions: every project" "# every project" "$(list "$SANDBOX" | head -n 1)"
assert_contains "here in tmux: its session, attached marked" "$(list "$W" | grep "^$A")" "sj-claude-widget*"
assert_contains "elsewhere: the host" "$(list "$W" | grep "^$D")" "@otherhost"
assert_contains "the title from the catalogue" "$(list "$W" | grep "^$C")" "retry backoff fix"
assert_eq "sj pick runs it" "$(list "$W")" "$(cd "$W" && bash "$APP/bin/sj.sh" pick --list)"
assert_eq "and so does sj with its flags" "$(list "$W" --live)" "$(cd "$W" && bash "$APP/bin/sj.sh" --list --live)"

section "Enter: whichever way back fits, never a second live copy"
assert_eq "here in tmux, from outside tmux: attach" "exec	sj-no-such-tmux	attach-session	-t	=sj-claude-widget" "$(plan "$A" | sed -n 2p)"
assert_eq "from inside tmux: switch" "switch	sj-claude-widget" "$(TMUX=/tmp/x,1,0 plan "$A" | sed -n 2p)"
assert_eq "from the popup too" "switch	sj-claude-widget" "$(TMUX=/tmp/x,1,0 plan "$A" --popup | sed -n 2p)"
assert_contains "here outside tmux: says where, does nothing" "$(plan "$B")" "outside tmux (pid 4242)"
assert_eq "  …nothing" "msg" "$(plan "$B" | sed -n 2p)"
assert_contains "stopped, transcript here: resume it in its folder" "$(plan "$C" | head -n 1)" "resume it in $W"
assert_eq "  …through sj resume" "exec	bash	$RAPP/bin/sj.sh	resume	$C" "$(plan "$C" | sed -n 2p)"
assert_eq "  …from the popup: in a new tmux session in that folder" "detach	$W	bash	$RAPP/bin/sj.sh	resume	$C" \
  "$(plan "$C" --popup | sed -n 2p)"
assert_contains "live on another host: attach there or hand off (sj resume asks)" "$(plan "$D" | head -n 1)" "it runs on otherhost"
assert_contains "recorded elsewhere: the hand-off" "$(plan "$H" | head -n 1)" "hand it off from the archive (otherhost)"
assert_eq "  …from the popup, into the folder it was opened in" "detach	$W	bash	$RAPP/bin/sj.sh	resume	$H" \
  "$(plan "$H" --popup | sed -n 2p)"
assert_contains "another harness: says so" "$(plan "$G")" "not a Claude session (opencode)"
check_fails "a prefix that matches nothing" plan zzzz

section "the panel: what tells sessions of one folder apart"
said() { python3 -c 'import importlib.util, json, sys
s = importlib.util.spec_from_file_location("p", sys.argv[1]); m = importlib.util.module_from_spec(s); sys.modules["p"] = m; s.loader.exec_module(m)
print(json.dumps(m.said(sys.argv[2])))' "$PICK" "$CLAUDE_CONFIG_DIR/projects/-w/$C.jsonl"; }
out="$(said)"
assert_eq "the first real prompt (not a caveat)" "make the retries back off" "$(jq -r .first <<<"$out")"
assert_eq "the last prompt: a command, as typed" "/sjlog now" "$(jq -r .last <<<"$out")"
assert_eq "the last reply's prose, its code folded" "Published the session, and the backoff now doubles up to 30 s.
[code]" "$(jq -r .reply <<<"$out")"
check_fails "no terminal: it says so" bash -c "python3 '$PICK' </dev/null >/dev/null 2>&1"

finish
