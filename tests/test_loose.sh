#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Loose ends (view/sj_view.py). What must hold: a PR the forge says is finished never shows, whatever
# the transcript saw; a branch with a PR is not loose; what cannot be checked says so.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
need_cmd python3 "loose ends" || { finish; exit 0; }

out="$(python3 - "$APP" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + "/view")
import sj_view as v

n = lambda s: {"sid": s, "sid8": s[:8], "topic": "t " + s, "date": "2026-11-07"}
gh = {"id": "github.com/acme/api", "kind": "github", "label": "acme/api"}
gl = {"id": "gitlab.com/acme/lib", "kind": "gitlab", "label": "acme/lib"}
loc = {"id": "git:h:/r", "kind": "repo", "label": "r"}
work = [
  {"node": n("a"), "artefact": gh, "root": "/r/api", "events": [
    {"type": "pr_open", "n": 1, "title": "still open"}, {"type": "pr_open", "n": 2, "title": "merged by hand"},
    {"type": "pr_open", "n": 3, "title": "merged here"}, {"type": "pr_merge", "n": 3},
    {"type": "push", "branch": "has-pr"}, {"type": "push", "branch": "no-pr"}, {"type": "push", "branch": "main"}]},
  {"node": n("b"), "artefact": gl, "root": "", "events": [{"type": "pr_open", "n": 9, "title": "mr"}]},
  {"node": n("c"), "artefact": loc, "root": "/r/clean", "events": []},
]
prs = [{"number": 1, "state": "OPEN", "headRefName": "x", "title": "still open", "url": "u1"},
       {"number": 2, "state": "MERGED", "headRefName": "y", "title": "m", "url": "u2"},
       {"number": 3, "state": "MERGED", "headRefName": "has-pr", "title": "m", "url": "u3"}]
disk = {"/r/api": {"ahead": 2, "dirty": 1}, "/r/clean": {"ahead": 0, "dirty": 0}}
d = v.died_items([{**n("x"), "project": "p"}, {**n("y"), "project": "p"}], {"x": {"state": "died"}, "y": {"state": "idle"}})
print(json.dumps({"died": d, "checked": v.loose_items(work, lambda r: prs, disk.get),
                  "offline": v.loose_items(work[:1], lambda r: None, disk.get)}))
PY
)"
what() { jq -r --arg k "$1" '.checked[] | select(.kind == $k) | .what' <<<"$out"; }

section "only what is really unfinished"
assert_eq "the open PR, with its title" "PR #1 still open: still open" "$(what pr | head -1)"
assert_eq "a PR merged by hand is gone; a GitLab MR stays, unchecked" 2 "$(what pr | wc -l | tr -d ' ')"
assert_eq "the branch with no PR; not one with a PR, not main" "branch no-pr pushed, no PR" "$(what branch)"
assert_eq "commits not pushed" "2 commits not pushed" "$(what unpushed)"
assert_eq "files not committed" "1 file not committed" "$(what dirty)"
assert_eq "a clean repo says nothing" 0 "$(jq '[.checked[] | select(.repo == "r")] | length' <<<"$out")"

section "a session that died mid-turn is one too"
assert_eq "only the one that died" x "$(jq -r '[.died[].sid] | join(" ")' <<<"$out")"

section "what could not be checked says so"
assert_eq "GitLab is not asked" false "$(jq -r '.checked[] | select(.repo == "acme/lib") | .checked' <<<"$out")"
assert_eq "no forge: the transcript's word, marked" "false false" \
  "$(jq -r '[.offline[] | select(.kind == "pr" or .kind == "branch") | .checked] | unique + [false] | join(" ")' <<<"$out")"
assert_eq "no forge: a PR it saw merged still is not listed" 0 "$(jq '[.offline[] | select(.what | test("#3"))] | length' <<<"$out")"
assert_eq "the disk needs no forge" true "$(jq -r '.offline[] | select(.kind == "dirty") | .checked' <<<"$out")"

finish
