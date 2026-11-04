#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The session viewer (bin/sj-view.sh + view/sj_view.py): started on demand, reachable only with its
# token, a map of the catalogue with forks as edges, and gone again on stop, on the page's Stop
# button, or after its idle time.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
need_cmd python3 "session viewer" || { finish; exit 0; }
need_cmd curl "session viewer" || { finish; exit 0; }

export SCRUBJAY_RUN_DIR="$SANDBOX/run"
STATE="$SCRUBJAY_RUN_DIR/view.json"
LOG="$SCRUBJAY_DATA/logs/testhost.log"
P="aaaaaaaa-1111-4111-8111-111111111111"   # parent
C="bbbbbbbb-2222-4222-8222-222222222222"   # its fork
O="ses_0123456789abcdefGHIJKL"             # an opencode session
X="cccccccc-3333-4333-8333-333333333333"   # another machine's
today="$(date +%Y-%m-%d)"
{
  echo "$today 09:00 | testhost | /home/user/widget-api | \"Retry backoff fires twice\" | session=$P | harness=claude | model=claude-opus-4-8 | turns=5 | size=2048"
  echo "$today 09:00 | testhost | /home/user/widget-api | \"Retry backoff + jitter\" | session=$P | harness=claude | model=claude-opus-4-8 | turns=9 | size=4096 | prompts=3"
  echo "$today 10:00 | testhost | /home/user/widget-api | \"Jitter experiment\" | session=$C | harness=claude | model=claude-opus-4-8 | turns=2 | size=1024 | forked_from=$P"
  echo "$today 11:00 | testhost | /home/user/widget-api | \"Port the client to opencode\" | session=$O | model= | turns=3 | size=900"
  echo "$today 12:00 | laptop | /home/user/widget-api | \"Laptop-side fix\" | session=$X | harness=claude | turns=4 | size=700"
  echo "$today 13:00 | testhost | /home/user/widget-api | \"\" | session=dddddddd-4444-4444-8444-444444444444 | harness=claude | turns= | size=0"
} > "$LOG"
read_md="$SCRUBJAY_LOCAL_CHATS/testhost/readable/widget-api/${today}_retry-backoff__aaaaaaaa.md"
mkdir -p "$(dirname "$read_md")"
printf '# Retry backoff\n\n_1 turns_\n\n## User\n\nwhy does the backoff fire twice?\n\n## Assistant\n\nBecause the timer is armed in both paths.\n' > "$read_md"

get() { curl -s -H "X-SJ-Token: $TOK" "http://127.0.0.1:$PORT$1"; }

section "start: one command, prints where it is, runs in the background"
out="$(bash "$APP/bin/sj-view.sh" --no-open --port 0 2>&1)"; rc=$?
assert_eq "start exits 0" 0 "$rc"
assert_contains "prints the address" "$out" "scrubjay view: http://127.0.0.1:"
assert_contains "says how to stop it" "$out" "/sjview stop"
assert_eq "the state file (it holds the token) is private" "$STATE" "$(find "$STATE" -perm 600)"
PORT="$(jq -r .port "$STATE")"; URL="$(jq -r .url "$STATE")"; TOK="${URL#*t=}"
again="$(bash "$APP/bin/sj-view.sh" --no-open 2>&1)"
assert_eq "a second start reuses the running one" "$URL" "$(jq -r .url "$STATE")"
assert_contains "and says where it is" "$again" "$URL"

section "only this page can read it"
assert_eq "no token: 403" 403 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/graph")"
assert_eq "wrong token: 403" 403 "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-SJ-Token: nope' "http://127.0.0.1:$PORT/api/graph")"
assert_eq "a foreign Host (DNS rebinding): 403" 403 "$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Host: evil.example:$PORT" -H "X-SJ-Token: $TOK" "http://127.0.0.1:$PORT/api/graph")"
assert_eq "the page with its token: 200" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$URL")"

section "the map: every session once, forks as edges"
g="$(get /api/graph)"
assert_eq "one node per session, earlier rows folded in" 5 "$(jq '.nodes | length' <<<"$g")"
assert_eq "the latest topic wins" "Retry backoff + jitter" "$(jq -r --arg s "$P" '.nodes[] | select(.sid == $s) | .topic' <<<"$g")"
assert_eq "the fork is an edge, parent to child" "$P>$C:fork" "$(jq -r '.edges[] | "\(.from)>\(.to):\(.kind)"' <<<"$g")"
assert_eq "an opencode id is an opencode session" opencode "$(jq -r --arg s "$O" '.nodes[] | select(.sid == $s) | .harness' <<<"$g")"
assert_eq "an archived transcript is marked" true "$(jq -r --arg s "$P" '.nodes[] | select(.sid == $s) | .archived' <<<"$g")"
assert_eq "this machine is named" testhost "$(jq -r .host <<<"$g")"

section "a session: all it holds, and how to continue it"
s="$(get "/api/session?sid=$P")"
assert_eq "every row, oldest first" "Retry backoff fires twice|Retry backoff + jitter" "$(jq -r '[.rows[].topic] | join("|")' <<<"$s")"
assert_eq "its fork is listed" "$C" "$(jq -r '.children[0]' <<<"$s")"
assert_eq "trailing fields kept" 3 "$(jq -r '.rows[-1].prompts' <<<"$s")"
assert_eq "here: the harness's own resume, in its folder" \
  "cd '/home/user/widget-api' && claude --resume $P" "$(jq -r .resume.cmd <<<"$s")"
x="$(get "/api/session?sid=$X")"
assert_eq "another machine's: fetched with sj-resume first" laptop "$(jq -r .resume.where <<<"$x")"
assert_contains "the sj-resume command" "$(jq -r .resume.cmd <<<"$x")" "sj-resume.sh' cccccccc"
assert_eq "an unknown session: 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' -H "X-SJ-Token: $TOK" "http://127.0.0.1:$PORT/api/session?sid=nope")"

section "the transcript"
t="$(get "/api/transcript?sid8=aaaaaaaa&format=readable")"
assert_contains "the readable text" "$(jq -r .content <<<"$t")" "Because the timer is armed in both paths."
assert_contains "a session with none says so" "$(get "/api/transcript?sid8=bbbbbbbb" | jq -r .error)" "not in the archive"
assert_contains "a path is not a session" "$(get "/api/transcript?sid8=../../../etc" | jq -r .error)" "not in the archive"

section "stop: the command, the page's button, and idle"
out="$(bash "$APP/bin/sj-view.sh" stop 2>&1)"
assert_contains "stop says so" "$out" "stopped"
check_fails "the port is closed" curl -s -o /dev/null "http://127.0.0.1:$PORT/"
assert_no_file "the state file is gone" "$STATE"
assert_contains "status: not running" "$(bash "$APP/bin/sj-view.sh" status)" "not running"
bash "$APP/bin/sj-view.sh" --no-open --port 0 >/dev/null 2>&1
PORT="$(jq -r .port "$STATE")"; URL="$(jq -r .url "$STATE")"; TOK="${URL#*t=}"
pid="$(jq -r .pid "$STATE")"
curl -s -X POST -H "X-SJ-Token: $TOK" "http://127.0.0.1:$PORT/api/stop" >/dev/null
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
check_fails "the Stop button ends the process" kill -0 "$pid"
assert_no_file "and removes the state file" "$STATE"
# --idle takes minutes; the server's own flag takes fractions, which is how this stays quick.
python3 "$APP/view/sj_view.py" --port 0 --idle 0.03 --state "$STATE" >/dev/null 2>&1 &
ipid=$!
for _ in $(seq 100); do kill -0 "$ipid" 2>/dev/null || break; sleep 0.1; done
check_fails "an unused viewer stops by itself" kill -0 "$ipid"

section "bad arguments are named"
assert_contains "a non-number port" "$(bash "$APP/bin/sj-view.sh" --port x 2>&1)" "--port needs a number"
assert_contains "an unknown flag" "$(bash "$APP/bin/sj-view.sh" --bogus 2>&1)" "unknown argument: --bogus"

finish
