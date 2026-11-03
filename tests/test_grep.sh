#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# sj-grep.sh: keyword search over the readable archive, scoped by the catalogue.
#
# What is worth pinning: ANY vs --all and the ranking (distinct terms, then hit lines, then
# recency), that scope filters and session targeting narrow what is searched rather than what is
# shown, that the turn/line numbers it prints are the ones sj_get slices by, the --json shape other
# tools consume, the distinct exit 3 that sends /sjgrep to its sjmcp fallback, and the cap.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

# ── the fixture archive ────────────────────────────────────────────────────────────────────────
#   aaaaaaaa  laptop/alpha  claude    borg ×3 lines + prune ×1   (2 terms, 4 hit lines)
#   bbbbbbbb  laptop/beta   opencode  Borg ×3 lines              (1 term, 3)
#   cccccccc  henpi/alpha   claude    prune ×1                   (1 term, 1, 2026-07-15)
#   dddddddd  henpi/misc    —         borg ×1, NOT catalogued    (1 term, 1, 2026-06-01)
#   eeeeeeee  catalogued, no readable copy
A="$SCRUBJAY_LOCAL_CHATS"
mkdir -p "$A/laptop/readable/alpha" "$A/laptop/readable/beta" "$A/henpi/readable/alpha" "$A/henpi/readable/misc"
cat > "$A/laptop/readable/alpha/2026-08-02_set-up-borg__aaaaaaaa.md" <<'EOF'
# set up borg backups

_4 turns_

## User

please configure the borg repository
## Assistant

Sure. First the retention policy.
filler one
filler two
## User

and prune weekly
## Assistant

done with borg
EOF
cat > "$A/laptop/readable/beta/2026-08-01_beta-work__bbbbbbbb.md" <<'EOF'
# beta work

_2 turns_

## User

Borg is the tool. BORG again.
## Assistant

we keep the retention short
Borg yes
borg and more borg
EOF
cat > "$A/henpi/readable/alpha/2026-07-15_gamma-work__cccccccc.md" <<'EOF'
# gamma work

_2 turns_

## User

should we prune old snapshots
## Assistant

maybe
EOF
cat > "$A/henpi/readable/misc/2026-06-01_uncatalogued__dddddddd.md" <<'EOF'
# uncatalogued

_2 turns_

## User

a borg question
## Assistant

an answer
EOF
{
  echo '2026-08-02 10:00 | laptop | /p/alpha | "set up borg" | session=aaaaaaaa-1111-4111-8111-111111111111 | harness=claude | model=opus | turns=4 | size=2048'
  echo '2026-08-01 09:00 | laptop | /p/beta | "beta work" | session=bbbbbbbb-1111-4111-8111-111111111111 | harness=opencode | model=gpt | turns=2 | size=1024'
  echo '2026-07-15 08:00 | henpi | /p/alpha | "gamma work" | session=cccccccc-1111-4111-8111-111111111111 | harness=claude | model=opus | turns=2 | size=512'
  echo '2026-07-01 07:00 | henpi | /p/zeta | "(no text)" | session=eeeeeeee-1111-4111-8111-111111111111 | harness=codex | model=gpt | turns=1 | size=256'
} > "$SCRUBJAY_DATA/logs/testhost.log"

g()     { bash "$APP/bin/sj-grep.sh" "$@" 2>/dev/null; }
gj()    { g --json "$@"; }
order() { gj "$@" | jq -r 'select(.type=="session") | .sid8' | tr '\n' ' ' | sed 's/ $//'; }
summ()  { local f="$1"; shift; gj "$@" | jq -r "select(.type==\"summary\") | $f"; }

section "ANY vs --all, and the ranking"
assert_eq "ANY ranks distinct terms, then hit lines, then recency" \
  "aaaaaaaa bbbbbbbb cccccccc dddddddd" "$(order borg prune)"
assert_eq "--all keeps only sessions with every term" "aaaaaaaa" "$(order --all borg prune)"
assert_eq "matching is case-insensitive" "aaaaaaaa bbbbbbbb dddddddd" "$(order BORG)"
assert_eq "a quoted phrase is one literal term" "aaaaaaaa" "$(order 'retention policy')"
assert_eq "regex metacharacters are literal" "" "$(order 'b.rg')"
assert_eq "an uncatalogued readable is still searched" "dddddddd" "$(order 'a borg question')"

section "scope filters narrow what is searched"
assert_eq "host="            "cccccccc dddddddd" "$(order borg prune host=henpi)"
assert_eq "harness="         "bbbbbbbb"          "$(order borg prune harness=opencode)"
assert_eq "model="           "bbbbbbbb"          "$(order borg prune model=gpt)"
assert_eq "project= (substring of the project dir)" "aaaaaaaa cccccccc" "$(order borg prune project=alp)"
assert_eq "since="           "aaaaaaaa bbbbbbbb" "$(order borg prune since=2026-08-01)"
assert_eq "until="           "cccccccc dddddddd" "$(order borg prune until=2026-07-31)"
assert_eq "topic="           "cccccccc"          "$(order borg prune topic=GAMMA)"
assert_eq "head=N searches only the newest N in scope" "aaaaaaaa" "$(order borg prune head=1)"
assert_eq "…and says how many it searched" "1" "$(summ .in_scope borg head=1)"
assert_eq "tail=N searches the oldest N" "dddddddd" "$(order borg prune tail=1)"
assert_eq "[a:b] slices the scope newest-first" "bbbbbbbb cccccccc" "$(order borg prune '[1:3]')"

section "session targeting"
assert_eq "session=<sid8>"          "bbbbbbbb" "$(order borg session=bbbbbbbb)"
assert_eq "a bare 8-hex arg is a session" "bbbbbbbb" "$(order bbbbbbbb borg)"
assert_eq "several, comma-separated" "aaaaaaaa bbbbbbbb" "$(order borg session=aaaaaaaa,bbbbbbbb)"
assert_eq "a full session id works too" "cccccccc" "$(order prune cccccccc-1111-4111-8111-111111111111)"
assert_contains "a session without a readable copy says so" \
  "$(bash "$APP/bin/sj-grep.sh" borg session=eeeeeeee 2>&1)" "eeeeeeee has no readable copy in this archive (catalogued on henpi)"
assert_eq "-e forces a hex-looking keyword to be a term" "" "$(order -e eeeeeeee)"
assert_eq "…and it is searched as one" "1" "$(summ .terms\|length -e deadbeef)"

section "snippets: turn and line numbers sj_get can slice by"
snips="$(gj borg prune session=aaaaaaaa | jq -c 'select(.type=="session") | [.snippets[] | [.turn,.line,.start,.end]]')"
assert_eq "title hit is turn 0; windows merge; ordered by line" "[[0,1,1,3],[1,7,5,9],[3,15,13,18]]" "$snips"
assert_eq "--max-snippets caps the windows" "1" \
  "$(gj borg prune session=aaaaaaaa --max-snippets=1 | jq 'select(.type=="session") | .snippets | length')"
assert_eq "context=0 is just the hit line" "[7,7]" \
  "$(gj borg session=aaaaaaaa context=0 --max-snippets=2 | jq -c 'select(.type=="session") | .snippets[1] | [.start,.end]')"
out="$(g borg prune session=aaaaaaaa)"
assert_contains "text marks the hit when not on a tty" "$out" "please configure the «borg» repository"
assert_contains "text flags hit lines and numbers them" "$out" ">     7  "
assert_contains "text names the turn and the slice" "$out" "turn 3, line 15  (sj_get turns=3 · lines=13-18)"
assert_contains "header carries handle, harness, host, project, date, topic" "$out" \
  "aaaaaaaa · claude · laptop · alpha · 2026-08-02 · set up borg"
assert_contains "and the hit counts per term" "$out" "4 hit lines, 2/2 terms (borg 3, prune 1)"
assert_contains "an uncatalogued session shows its filename metadata" \
  "$(g borg session=dddddddd)" "dddddddd · - · henpi · misc · 2026-06-01 · uncatalogued"

section "--json shape"
json="$(gj borg prune)"
assert_eq "every line is one JSON object" "5" "$(printf '%s\n' "$json" | jq -c . | wc -l | tr -d ' ')"
assert_eq "session rows carry the documented keys" \
  '["date","harness","hits","host","path","project","rank","sid","sid8","snippets","term_hits","terms_hit","topic","ts","turns","type"]' \
  "$(printf '%s\n' "$json" | jq -c 'select(.rank==1) | keys')"
assert_eq "term_hits counts lines per term" '{"borg":3,"prune":1}' \
  "$(printf '%s\n' "$json" | jq -c 'select(.rank==1) | .term_hits')"
assert_eq "turns comes from the readable header" "4" "$(printf '%s\n' "$json" | jq 'select(.rank==1) | .turns')"
assert_eq "the full session id rides along" "aaaaaaaa-1111-4111-8111-111111111111" \
  "$(printf '%s\n' "$json" | jq -r 'select(.rank==1) | .sid')"
assert_eq "the summary closes the stream" '{"mode":"any","in_scope":4,"matched":4,"shown":4,"capped":false}' \
  "$(printf '%s\n' "$json" | tail -1 | jq -c '{mode,in_scope,matched,shown,capped}')"
assert_eq "snippet text is unmarked in JSON" "please configure the borg repository" \
  "$(printf '%s\n' "$json" | jq -r 'select(.rank==1) | .snippets[1].text' | sed -n 3p)"

section "capping"
assert_eq "--limit bounds the sessions shown" "aaaaaaaa" "$(order borg prune --limit=1)"
assert_eq "…and the summary says it capped" "true 4 1" "$(summ '"\(.capped) \(.matched) \(.shown)"' borg prune --limit 1)"
assert_contains "text says how many were held back" "$(g borg prune --limit=2)" "2 more matching sessions not shown"
assert_contains "text header says it is showing the best N" "$(g borg prune --limit=2)" "4 of 4 sessions in scope mention any of \"borg\", \"prune\" — showing the best 2"

section "exit codes"
g borg >/dev/null; assert_eq "0 when something matches" "0" "$?"
g nothing-like-this >/dev/null; assert_eq "1 when nothing matches" "1" "$?"
assert_contains "and says so" "$(g nothing-like-this)" "no session in scope (4 searched) mentions any of"
g >/dev/null; assert_eq "2 with no keywords" "2" "$?"
g borg colour=red >/dev/null; assert_eq "2 for an unknown filter" "2" "$?"
out="$(SCRUBJAY_TRANSCRIPT_BACKEND=rsync-wg bash "$APP/bin/sj-grep.sh" borg 2>&1)"; rc=$?
assert_eq "3 on rsync-wg — no filesystem view of the archive" "3" "$rc"
assert_contains "…with the sjmcp fallback named" "$out" "no-archive"
SCRUBJAY_LOCAL_CHATS="$SANDBOX/not-mounted" bash "$APP/bin/sj-grep.sh" borg >/dev/null 2>&1
assert_eq "3 when the archive root is missing (NAS not mounted)" "3" "$?"
mkdir -p "$SANDBOX/chats"; cp -a "$A/." "$SANDBOX/chats/"
assert_eq "the git backend reads the scrubjay-chats clone" "aaaaaaaa" \
  "$(SCRUBJAY_TRANSCRIPT_BACKEND=git SCRUBJAY_CHATS="$SANDBOX/chats" SCRUBJAY_LOCAL_CHATS="" \
     bash "$APP/bin/sj-grep.sh" --json --all borg prune 2>/dev/null | jq -r 'select(.type=="session") | .sid8')"

finish
