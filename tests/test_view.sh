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
X="cccccccc-3333-4333-8333-333333333333"   # started on another machine, continued here
Y="99999999-3333-4333-8333-333333333333"   # another machine's alone
today="$(date +%Y-%m-%d)"
{
  echo "$today 09:00 | testhost | /home/user/widget-api | \"Retry backoff fires twice\" | session=$P | harness=claude | model=claude-opus-4-8 | turns=5 | size=2048"
  echo "$today 09:00 | testhost | /home/user/widget-api | \"Retry backoff + jitter\" | session=$P | harness=claude | model=claude-opus-4-8 | turns=9 | size=4096 | prompts=3 | summary=Armed the retry timer once; PR #42 merged."
  echo "$today 10:00 | testhost | /home/user/widget-api | \"Jitter experiment\" | session=$C | harness=claude | model=claude-opus-4-8 | turns=2 | size=1024 | forked_from=$P"
  echo "$today 12:00 | laptop | /home/user/widget-api | \"Laptop-side fix\" | session=$X | harness=claude | turns=4 | size=700"
  echo "$today 14:00 | testhost | /home/user/widget-api | \"Laptop-side fix, finished here\" | session=$X | harness=claude | turns=9 | size=1700 | resumed_from=laptop:$X"
  echo "$today 15:00 | testhost | /home/user/widget-api | \"Port the client to opencode\" | session=$O | model= | turns=3 | size=900 | resumed_from=laptop:$X"
  echo "$today 12:30 | laptop | /home/user/widget-api | \"Laptop only\" | session=$Y | harness=claude | turns=2 | size=500"
  echo "$today 13:00 | testhost | /home/user/widget-api | \"\" | session=dddddddd-4444-4444-8444-444444444444 | harness=claude | turns= | size=0"
} > "$LOG"
read_md="$SCRUBJAY_LOCAL_CHATS/testhost/readable/widget-api/${today}_retry-backoff__aaaaaaaa.md"
mkdir -p "$(dirname "$read_md")"
# The parent's transcript, in the shape every renderer emits: writes in the repo, outside it, to
# memory and to scratch; a branch, a commit, a push, a PR opened and merged, an issue.
cat > "$read_md" <<'MD'
# Retry backoff

_2 turns_

## User

why does the backoff fire twice?

## Assistant

Because the timer is armed in both paths.

**→ Edit**

```json
{"file_path":"/home/user/widget-api/src/retry.ts","old_string":"a","new_string":"b"}
```

**⎿ output:**

```text
The file has been updated.
```

**→ Write**

```json
{"file_path":"/home/user/notes/backoff.md","content":"x"}
```

**→ Write**

```json
{"file_path":"/home/user/.claude/projects/-home-user-widget-api/memory/retry.md","content":"x"}
```

**→ Write**

```json
{"file_path":"/tmp/scratch.txt","content":"x"}
```

**⎿ output:**

```text
ok
```

**⎿ output:**

```text
ok
```

**⎿ output:**

```text
ok
```

**→ Bash**

```bash
git checkout -q -b fix/backoff && git commit -qam "fix: arm the retry timer once" && git push -q -u origin fix/backoff 2>&1 | tail -1
```

**⎿ output:**

```text
```

**→ Bash**

```bash
gh pr create --title "Arm the retry timer once" --body "x" 2>&1 | tail -1
```

**⎿ output:**

```text
https://github.com/acme/widget-api/pull/42
```

**→ Bash**

```bash
gh pr merge 42 --squash --delete-branch && gh issue create --title "Jitter is missing" --body "y"
```

**⎿ output:**

```text
https://github.com/acme/widget-api/issues/43
```

**→ Bash**

```bash
cat > notes.md <<'EOF'
**→ Bash**

```bash
git push origin quoted-not-run
```

**⎿ output:**

```text
```
EOF
```

**⎿ output:**

```text
```

**→ Bash**

```bash
grep -rn 'gh pr create\|git commit' ~/old-notes | head -1
```

**⎿ output:**

```text
notes.md:3: https://github.com/elsewhere/thing/pull/7
```

**→ Bash**

```bash
git push origin main
```

**⎿ error:**

```text
! [rejected] main -> main (fetch first)
```
MD
# The opencode session works in a repo with TWO remotes, opens a GitLab MR through the API from a
# scratch folder, comments upstream on GitHub, and reads an unrelated repo's releases.
oc_md="$SCRUBJAY_LOCAL_CHATS/testhost/readable/widget-api/${today}_port__01234567.md"
cat > "$oc_md" <<'MD'
# Port

## Assistant

**→ bash**

```bash
cd /home/user/greyk && git remote -v
```

**⎿ output:**

```text
origin	git@github.com:me/greyk.git (fetch)
origin	git@github.com:me/greyk.git (push)
gitlab	https://gitlab.com/team/greyk.git (fetch)
gitlab	https://gitlab.com/team/greyk.git (push)
```

**→ bash**

```bash
cd /home/user/greyk && git push -q gitlab feat-x:feat-x
```

**⎿ output:**

```text
```

**→ bash**

```bash
cd /tmp/scratch && N=$(glab api -X POST "projects/team%2Fgreyk/merge_requests" -f source_branch=feat-x -f title=x | jq .iid); echo "made !$N"; glab api "projects/team%2Fgreyk/merge_requests?state=opened" | jq -r '.[].web_url'
```

**⎿ output:**

```text
made !12
https://gitlab.com/team/greyk/-/merge_requests/11
```

**→ bash**

```bash
gh api repos/someone/else/releases --jq '.[0].html_url'; gh issue comment 5 -R upstream/lib --body "same here"
```

**⎿ output:**

```text
https://github.com/someone/else/releases/tag/v1
https://github.com/upstream/lib/issues/5#issuecomment-1
```
MD
# The fork's transcript starts with all of that, then does one thing of its own.
fork_md="$SCRUBJAY_LOCAL_CHATS/testhost/readable/widget-api/${today}_jitter__bbbbbbbb.md"
{ cat "$read_md"; printf '\n**→ Bash**\n\n```bash\ngit commit -qm "try jitter"\n```\n\n**⎿ output:**\n\n```text\n```\n'; } > "$fork_md"

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
page="$(curl -s "$URL")"
assert_contains "the page pans and zooms (drag, wheel, keys, the zoom bar)" "$page" 'id="zoombar"'
assert_contains "and draws only the cards near the view" "$page" "function cull()"

section "the map: every session once, forks as edges"
g="$(get /api/graph)"
assert_eq "one node per session, earlier rows folded in" 6 "$(jq '.nodes | length' <<<"$g")"
assert_eq "the latest topic wins" "Retry backoff + jitter" "$(jq -r --arg s "$P" '.nodes[] | select(.sid == $s) | .topic' <<<"$g")"
assert_eq "the fork is an edge, parent to child" "$P>$C:fork" "$(jq -r '.edges[] | select(.kind == "fork") | "\(.from)>\(.to):\(.kind)"' <<<"$g")"
assert_eq "an opencode id is an opencode session" opencode "$(jq -r --arg s "$O" '.nodes[] | select(.sid == $s) | .harness' <<<"$g")"
assert_eq "an archived transcript is marked" true "$(jq -r --arg s "$P" '.nodes[] | select(.sid == $s) | .archived' <<<"$g")"
assert_eq "this machine is named" testhost "$(jq -r .host <<<"$g")"

section "summaries and hand-offs"
assert_eq "the summary is on the node" "Armed the retry timer once; PR #42 merged." \
  "$(jq -r --arg s "$P" '.nodes[] | select(.sid == $s) | .summary' <<<"$g")"
assert_eq "a hand-off: one node, both machines in order" "laptop testhost" \
  "$(jq -r --arg s "$X" '.nodes[] | select(.sid == $s) | .hosts | join(" ")' <<<"$g")"
assert_eq "it now lives here" testhost "$(jq -r --arg s "$X" '.nodes[] | select(.sid == $s) | .host' <<<"$g")"
assert_eq "a carry-over: an edge from the source" "$X>$O:carry" \
  "$(jq -r '.edges[] | select(.kind == "carry") | "\(.from)>\(.to):\(.kind)"' <<<"$g")"
assert_eq "a native hand-off is not an edge" 1 "$(jq '[.edges[] | select(.kind == "carry")] | length' <<<"$g")"

section "a session: all it holds, and how to continue it"
s="$(get "/api/session?sid=$P")"
assert_eq "every row, oldest first" "Retry backoff fires twice|Retry backoff + jitter" "$(jq -r '[.rows[].topic] | join("|")' <<<"$s")"
assert_eq "its fork is listed" "$C" "$(jq -r '.children[0]' <<<"$s")"
assert_eq "trailing fields kept" 3 "$(jq -r '.rows[-1].prompts' <<<"$s")"
assert_eq "here: the harness's own resume, in its folder" \
  "cd '/home/user/widget-api' && claude --resume $P" "$(jq -r .resume.cmd <<<"$s")"
x="$(get "/api/session?sid=$Y")"
assert_eq "another machine's: fetched with sj-resume first" laptop "$(jq -r .resume.where <<<"$x")"
assert_contains "the sj-resume command" "$(jq -r .resume.cmd <<<"$x")" "sj-resume.sh' 99999999"
assert_eq "an unknown session: 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' -H "X-SJ-Token: $TOK" "http://127.0.0.1:$PORT/api/session?sid=nope")"

section "the transcript"
t="$(get "/api/transcript?sid8=aaaaaaaa&format=readable")"
assert_contains "the readable text" "$(jq -r .content <<<"$t")" "Because the timer is armed in both paths."
assert_contains "a session with none says so" "$(get "/api/transcript?sid8=cccccccc" | jq -r .error)" "not in the archive"
assert_contains "a path is not a session" "$(get "/api/transcript?sid8=../../../etc" | jq -r .error)" "not in the archive"

section "artefacts: what the sessions changed, and the milestones"
for _ in $(seq 50); do [ "$(get /api/graph | jq -c .indexing)" = null ] && break; sleep 0.1; done
g="$(get /api/graph)"
ids="$(jq -r '[.artefacts[].id] | sort | join(" ")' <<<"$g")"
assert_contains "the GitHub repo, named by the PR the session opened" "$ids" "github.com/acme/widget-api"
assert_contains "a folder outside the repo" "$ids" "dir:testhost:/home/user/notes"
assert_contains "the project's memory" "$ids" "memory:widget-api"
case "$ids" in *tmp*) _no "scratch space is not an artefact" "$ids" ;; *) _ok "scratch space is not an artefact" ;; esac
assert_eq "kinds are told apart" "folder github gitlab record" "$(jq -r '[.artefacts[].kind] | unique | join(" ")' <<<"$g")"
assert_eq "the edge says what the session did" "PR #42 merged · issue #43 · 1 commit · 1 file" \
  "$(jq -r --arg s "$P" '.edges[] | select(.from == $s and .to == "github.com/acme/widget-api") | .summary' <<<"$g")"
a="$(get "/api/artefact?id=github.com/acme/widget-api")"
pev="$(jq -c --arg s "$P" '.sessions[] | select(.node.sid == $s) | .events' <<<"$a")"
assert_eq "milestones in order" "branch commit push pr_open pr_merge issue_open" "$(jq -r 'map(.type) | join(" ")' <<<"$pev")"
assert_eq "the commit message, from -qam" "fix: arm the retry timer once" "$(jq -r '.[] | select(.type == "commit") | .title' <<<"$pev")"
assert_eq "the pushed branch, not the redirection" "fix/backoff" "$(jq -r '.[] | select(.type == "push") | .branch' <<<"$pev")"
case "$pev" in *quoted-not-run*) _no "a tool call quoted inside a command is not a call" "$pev" ;;
  *) _ok "a tool call quoted inside a command is not a call" ;; esac
assert_eq "a rejected push is not a push" 1 "$(jq '[.[] | select(.type == "push")] | length' <<<"$pev")"
assert_eq "the PR links to GitHub" "https://github.com/acme/widget-api/pull/42" "$(jq -r '.[] | select(.type == "pr_merge") | .url' <<<"$pev")"
assert_eq "the PR's title" "Arm the retry timer once" "$(jq -r '.[] | select(.type == "pr_open") | .title' <<<"$pev")"
assert_eq "the fork shows only what it did after branching" '["commit:try jitter"]' \
  "$(jq -c --arg s "$C" '[.sessions[] | select(.node.sid == $s) | .events[] | "\(.type):\(.title)"]' <<<"$a")"
assert_eq "a session lists what it changed" 3 "$(get "/api/session?sid=$P" | jq '.artefacts | length')"
assert_eq "an unknown artefact: 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' -H "X-SJ-Token: $TOK" "http://127.0.0.1:$PORT/api/artefact?id=nope")"
sumto() { jq -r --arg s "$1" --arg a "$2" '.edges[] | select(.from == $s and .to == $a) | .summary' <<<"$g"; }
assert_eq "an MR opened through the API, by the !N it printed (not the listing)" "MR !12 opened" "$(sumto "$O" gitlab.com/team/greyk)"
assert_eq "gh -R names the repo it commented on" "comment on #5" "$(sumto "$O" github.com/upstream/lib)"
case "$(jq -r '[.artefacts[].id] | join(" ")' <<<"$g")" in *elsewhere/thing*) _no "words a grep searches for are not commands" "$ids" ;;
  *) _ok "words a grep searches for are not commands" ;; esac
case "$(jq -r '[.artefacts[].id] | join(" ")' <<<"$g")" in *someone/else*) _no "an unrelated URL in an output is no artefact" "$ids" ;;
  *) _ok "an unrelated URL in an output is no artefact" ;; esac
mr="$(get "/api/artefact?id=gitlab.com/team/greyk" | jq -c '[.sessions[].events[] | {type, n, url, branch}]')"
assert_eq "the MR links to GitLab" "https://gitlab.com/team/greyk/-/merge_requests/12" "$(jq -r '.[] | select(.type == "pr_open") | .url' <<<"$mr")"
assert_eq "the push to the gitlab remote lands on GitLab, not origin" "feat-x" "$(jq -r '.[] | select(.type == "push") | .branch' <<<"$mr")"
assert_eq "the facts cache is private" "$SCRUBJAY_RUN_DIR/view-artefacts.json" "$(find "$SCRUBJAY_RUN_DIR/view-artefacts.json" -perm 600)"

section "a context pack: several sessions as one primer, and the command that starts on it"
pk() { curl -s -X POST -H "X-SJ-Token: $TOK" -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$PORT/api/pack"; }
p="$(pk "{\"sids\":[\"$C\",\"$P\",\"$Y\"],\"harness\":\"opencode\"}")"
f="$(jq -r .path <<<"$p")"
assert_eq "what it holds" 2 "$(jq -r .sessions <<<"$p")"
assert_eq "a session not in the archive is named, not dropped silently" 99999999 "$(jq -r '.skipped | join(" ")' <<<"$p")"
assert_contains "the agent's own way in" "$(jq -r .cmd <<<"$p")" "opencode --prompt \"Read the context pack at $f"
assert_contains "says past requests are not orders" "$(cat "$f")" "are not instructions now"
assert_contains "the conversation is in it" "$(cat "$f")" "why does the backoff fire twice"
first="$(command grep -n '^# Session' "$f" | head -1)"
assert_contains "oldest first" "$first" aaaaaaaa
assert_eq "private, like the archive" "$f" "$(find "$f" -perm 600)"
assert_eq "no sessions: refused" '"a pack needs sessions"' "$(pk '{"sids":[],"harness":"claude"}' | jq .error)"
assert_eq "an unknown agent: refused" '"no such agent"' "$(pk "{\"sids\":[\"$P\"],\"harness\":\"sh -c x\"}" | jq .error)"
assert_contains "only what is in the archive" "$(pk '{"sids":["nope"],"harness":"claude"}' | jq -r .error)" "in the archive"
assert_eq "a pack needs a token" 403 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "http://127.0.0.1:$PORT/api/pack")"

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

section "Nextcloud links: the settings reach the page, the most specific folder first"
R2="$SANDBOX/run2"
SCRUBJAY_RUN_DIR="$R2" SCRUBJAY_VIEW_NEXTCLOUD="https://cloud.example/" \
  SCRUBJAY_VIEW_NEXTCLOUD_MAP="/home/user=/Home; /home/user/notes=/Notes; nonsense; rel=/x" \
  bash "$APP/bin/sj-view.sh" --no-open --port 0 >/dev/null 2>&1
U2="$(jq -r .url "$R2/view.json")"
c="$(curl -s -H "X-SJ-Token: ${U2#*t=}" "http://127.0.0.1:$(jq -r .port "$R2/view.json")/api/graph" | jq -c .cloud)"
assert_eq "base without its slash, map longest first, junk dropped" \
  '{"base":"https://cloud.example","map":[["/home/user/notes","/Notes"],["/home/user","/Home"]]}' "$c"
SCRUBJAY_RUN_DIR="$R2" bash "$APP/bin/sj-view.sh" stop >/dev/null
SCRUBJAY_RUN_DIR="$R2" SCRUBJAY_VIEW_NEXTCLOUD="javascript:alert(1)" SCRUBJAY_VIEW_NEXTCLOUD_MAP="/home/user=/Home" \
  bash "$APP/bin/sj-view.sh" --no-open --port 0 >/dev/null 2>&1
U2="$(jq -r .url "$R2/view.json")"
assert_eq "an address that is not http(s) gives no links" null \
  "$(curl -s -H "X-SJ-Token: ${U2#*t=}" "http://127.0.0.1:$(jq -r .port "$R2/view.json")/api/graph" | jq -c .cloud)"
SCRUBJAY_RUN_DIR="$R2" bash "$APP/bin/sj-view.sh" stop >/dev/null

section "Nextcloud links follow the disk: a missing path opens what is left of it"
sh="$SANDBOX/share"; mkdir -p "$sh/a/b c"; : > "$sh/a/b c/file 1.txt"
SCRUBJAY_RUN_DIR="$R2" SCRUBJAY_VIEW_NEXTCLOUD="https://cloud.example" SCRUBJAY_VIEW_NEXTCLOUD_MAP="$sh=/Share" \
  bash "$APP/bin/sj-view.sh" --no-open --port 0 >/dev/null 2>&1
U2="$(jq -r .url "$R2/view.json")"; P2="$(jq -r .port "$R2/view.json")"
go() { curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -G --data-urlencode "t=${U2#*t=}" \
  --data-urlencode "path=$1" "http://127.0.0.1:$P2/go"; }
assert_eq "a file that exists: its folder, the file picked out" \
  "302 https://cloud.example/apps/files/files?dir=/Share/a/b%20c&scrollto=file%201.txt" "$(go "$sh/a/b c/file 1.txt")"
assert_eq "a file that is gone: its folder" "302 https://cloud.example/apps/files/files?dir=/Share/a/b%20c" "$(go "$sh/a/b c/gone.md")"
assert_eq "a deeper path that is gone: the deepest folder left" "302 https://cloud.example/apps/files/files?dir=/Share/a" "$(go "$sh/a/x/y/z.md")"
assert_eq "a folder: itself" "302 https://cloud.example/apps/files/files?dir=/Share" "$(go "$sh")"
assert_eq "outside the mapped folder: no link" "404 " "$(go /etc/passwd)"
ln -s /etc "$sh/out"
assert_eq "a symlink out of the mapped folder: never followed, the folder itself" "302 https://cloud.example/apps/files/files?dir=/Share" "$(go "$sh/out/passwd")"
assert_eq "climbing out with ..: no link" "404 " "$(go "$sh/../../etc/passwd")"
assert_eq "no token: no redirect" 403 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P2/go?path=$sh")"
SCRUBJAY_RUN_DIR="$R2" bash "$APP/bin/sj-view.sh" stop >/dev/null

section "--json, for a front-end that opens the address itself"
R3="$SANDBOX/run3"
assert_eq "status when stopped" '{"running":false}' "$(SCRUBJAY_RUN_DIR="$R3" bash "$APP/bin/sj-view.sh" status --json)"
j="$(env -u SSH_CONNECTION SCRUBJAY_RUN_DIR="$R3" bash "$APP/bin/sj-view.sh" --json --port 0)"
assert_eq "start: one JSON object, the address in it" true "$(jq -r '.running and (.url | startswith("http://127.0.0.1:"))' <<<"$j")"
assert_eq "no SSH here: no tunnel hint" null "$(jq -r .ssh <<<"$j")"
assert_eq "over SSH: the tunnel to open" "ssh -L $(jq -r .port <<<"$j"):127.0.0.1:$(jq -r .port <<<"$j") testhost" \
  "$(SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22" SCRUBJAY_RUN_DIR="$R3" bash "$APP/bin/sj-view.sh" status --json | jq -r .ssh)"
assert_eq "stop" '{"running":false}' "$(SCRUBJAY_RUN_DIR="$R3" bash "$APP/bin/sj-view.sh" stop --json)"

section "a project, even misspelt, opens the map on its lane"
echo "$today 16:00 | testhost | /home/user/Gadget_Firmware | \"Flash layout\" | session=eeeeeeee-5555-4555-8555-555555555555 | harness=claude | turns=2 | size=300" >> "$LOG"
R4="$SANDBOX/run4"
for q in widget-api WIDGET_API widgetapi widget gadget_firmwre; do
  case "$q" in gadget*) exp=Gadget_Firmware ;; *) exp=widget-api ;; esac
  assert_eq "\"$q\" is $exp" "$exp" "$(SCRUBJAY_RUN_DIR="$R4" bash "$APP/bin/sj-view.sh" "$q" --json --port 0 | jq -r .project)"
done
j="$(SCRUBJAY_RUN_DIR="$R4" bash "$APP/bin/sj-view.sh" widget --json)"
assert_eq "the address opens that lane" "#project=widget-api" "#$(jq -r '.url | split("#")[1]' <<<"$j")"
out="$(SCRUBJAY_RUN_DIR="$R4" bash "$APP/bin/sj-view.sh" widgit --no-open)"
assert_contains "says what it matched" "$out" 'project: widget-api (for "widgit")'
out="$(SCRUBJAY_RUN_DIR="$R4" bash "$APP/bin/sj-view.sh" zzqqxx --no-open)"
assert_contains "no likeness: all of them, and says so" "$out" 'no project like "zzqqxx"'
assert_eq "no likeness: a plain address" null "$(SCRUBJAY_RUN_DIR="$R4" bash "$APP/bin/sj-view.sh" zzqqxx --json | jq .project)"
assert_contains "the page reads #project=" "$(cat "$APP/view/index.html")" 'h.get("project")'
SCRUBJAY_RUN_DIR="$R4" bash "$APP/bin/sj-view.sh" stop >/dev/null

section "bad arguments are named"
assert_contains "a non-number port" "$(bash "$APP/bin/sj-view.sh" --port x 2>&1)" "--port needs a number"
assert_contains "an unknown flag" "$(bash "$APP/bin/sj-view.sh" --bogus 2>&1)" "unknown argument: --bogus"
assert_contains "two projects" "$(bash "$APP/bin/sj-view.sh" one two 2>&1)" "one project at a time"

finish
