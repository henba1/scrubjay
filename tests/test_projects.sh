#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Project links (bin/sj-projects.sh) and what the viewer makes of them. What must hold: the newest
# word on a project wins, no link closes a loop, a session sits where its project stood that day,
# and a suggestion never comes from a folder that merely holds other projects.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

L="$APP/bin/sj-projects.sh"
led() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$SCRUBJAY_DATA/projects/testhost.tsv"; }

section "add, undo, list"
assert_eq "no ledger: nothing in force" "" "$(bash "$L" list)"
bash "$L" add oldname newname 2026-03-01
assert_eq "recorded with its date" "$(printf 'oldname\tnewname\t2026-03-01')" "$(bash "$L" list)"
assert_file "in this machine's own file" "$SCRUBJAY_DATA/projects/testhost.tsv"
bash "$L" add sub parent
assert_contains "no date: always one project" "$(bash "$L" list)" "$(printf 'sub\tparent\t')"
bash "$L" undo oldname; bash "$L" undo sub
assert_eq "undone" "" "$(bash "$L" list)"

section "what add refuses"
assert_contains "into itself" "$(bash "$L" add a a 2>&1)" "into itself"
assert_contains "a bad date" "$(bash "$L" add a b yesterday 2>&1)" "not a date"
assert_contains "a tab" "$(bash "$L" add "$(printf 'a\tb')" c 2>&1)" "tab or line break"
assert_contains "no name" "$(bash "$L" add "" c 2>&1)" "needs a name"
check_fails "and says so by its exit code" bash "$L" add a a
bash "$L" add a b; bash "$L" add b c
assert_contains "a loop, directly" "$(bash "$L" add b a 2>&1)" "already flows into"
assert_contains "a loop, through another" "$(bash "$L" add c a 2>&1)" "already flows into"
bash "$L" undo a; bash "$L" undo b

section "the newest word wins, whichever machine said it"
rm -rf "$SCRUBJAY_DATA/projects"; mkdir -p "$SCRUBJAY_DATA/projects"
led 100 a b 2026-01-01
led 300 a c 2026-02-02
printf '200\ta\td\t\n' > "$SCRUBJAY_DATA/projects/laptop.tsv"
assert_eq "by time, across files" "$(printf 'a\tc\t2026-02-02')" "$(bash "$L" list)"
led 400 a "" ""
assert_eq "an undo counts as a word" "" "$(bash "$L" list)"

section "where a session sits, and what the viewer suggests"
out="$(python3 - "$APP" <<'PY'
import sys
sys.path[:0] = [sys.argv[1] + "/view", sys.argv[1] + "/mcp"]
import artefacts as art
import sj_view as v

L = {"a": {"from": "a", "into": "b", "at": "2026-03-01"}, "b": {"from": "b", "into": "c", "at": ""},
     "x": {"from": "x", "into": "y", "at": ""}, "y": {"from": "y", "into": "x", "at": ""}}
def show(name, got): print(f"{name}={got}")
show("before", v.follow("a", L, "2026-02-28"))
show("on", v.follow("a", L, "2026-03-01"))
show("whole", v.follow("a", L))
show("loop", v.follow("x", L))
show("none", v.follow("", L))

def node(p, path, date="2026-01-01", host="h", sid=None):
    return {"project": p, "cwd": path, "host": host, "date": date, "sid": sid or p + path + date}
def sug(nodes, edges=(), arts=None, links=None):
    return sorted((s["from"], s["into"], s["at"]) for s in v.suggest_links(nodes, list(edges), arts or {}, links or {}))
base = "/home/u/code"
show("child", sug([node("paper", base + "/sketch/paper"), node("sketch", base + "/sketch")]))
show("deep", sug([node("x", base + "/sketch/a/x"), node("sketch", base + "/sketch")]))
show("hidden", sug([node("app", "/home/u/.wrap/app"), node(".wrap", "/home/u/.wrap")]))
show("shelf", sug([node(p, f"{base}/{p}") for p in "abc"] + [node("code", base)]))
show("other host", sug([node("paper", base + "/sketch/paper", host="g"), node("sketch", base + "/sketch")]))
show("temp", sug([node("t", "/tmp/s/t"), node("s", "/tmp/s")]))
show("linked", sug([node("paper", base + "/sketch/paper"), node("sketch", base + "/sketch")],
                   links={"paper": {"from": "paper", "into": "sketch", "at": ""}}))
def landing(p, repo, n=2, date="2026-01-01"):
    ns = [node(p, f"{base}/{p}", date, sid=f"{p}{i}") for i in range(n)]
    return ns, [{"kind": "artefact", "from": x["sid"], "to": repo} for x in ns]
A = {"r1": {"id": "r1", "kind": "github", "label": "me/new-name"}, "r2": {"id": "r2", "kind": "github", "label": "me/other"},
     "f": {"id": "f", "kind": "folder", "label": "me/new-name"}}
n1, e1 = landing("oldname", "r1"); n2, _ = landing("new_name", "r2", 1)
show("named", sug(n1 + n2, e1, A))
n1, e1 = landing("one", "r2", 3); n2, e2 = landing("two", "r2", 2, "2026-02-01")
show("shared overlap", sug(n1 + n2 + [node("one", base + "/one", "2026-03-01")], e1 + e2, A))
n1, e1 = landing("one", "r2", 2); n2, e2 = landing("two", "r2", 3, "2026-02-01")
show("shared rename", sug(n1 + n2, e1 + e2, A))
n1, e1 = landing("one", "f", 3); n2, e2 = landing("two", "f", 3)
show("a folder is no remote", sug(n1 + n2, e1 + e2, A))
n1, e1 = landing("one", "r2", 1); n2, e2 = landing("two", "r2", 1)
show("one session is no home", sug(n1 + n2, e1 + e2, A))

claude = b'{"timestamp":"2026-01-01T10:00:00.000Z"}\n{"timestamp":"2026-01-01T10:10:00.000Z"}\n{"timestamp":"2026-01-01T12:00:00.000Z"}\n'
show("bursts", art.bursts(claude))
show("millis", art.bursts(b'{"time":{"created":1767261600000,"completed":1767261660000}}'))
show("empty", art.bursts(b"{}"))
show("joined", art.joined([[300, 400], [0, 100], [5000, 5000]]))
PY
)"
val() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
assert_eq "before the date it stands where it was" a "$(val before)"
assert_eq "from the date it has joined, and on through an always-link" c "$(val on)"
assert_eq "without a date, where it ends up" c "$(val whole)"
assert_eq "two machines' half loops stop the walk" y "$(val loop)"
assert_eq "no folder stays no folder" "" "$(val none)"
assert_eq "a folder directly inside a project" "[('paper', 'sketch', '')]" "$(val child)"
assert_eq "further down is not that" "[]" "$(val deep)"
assert_eq "a hidden wrapper is no project" "[]" "$(val hidden)"
assert_eq "a folder of projects is a shelf" "[]" "$(val shelf)"
assert_eq "another machine's folder is not inside this one's" "[]" "$(val 'other host')"
assert_eq "scratch is not a project" "[]" "$(val temp)"
assert_eq "already linked: nothing to suggest" "[]" "$(val linked)"
assert_eq "work on a repo named after another project flows into it" "[('oldname', 'new_name', '')]" "$(val named)"
assert_eq "same remote, side by side: the busier is the trunk" "[('two', 'one', '')]" "$(val 'shared overlap')"
assert_eq "same remote, one after the other: a rename, dated" "[('one', 'two', '2026-02-01')]" "$(val 'shared rename')"
assert_eq "a shared folder says nothing" "[]" "$(val 'a folder is no remote')"
assert_eq "one session makes no home" "[]" "$(val 'one session is no home')"
assert_eq "a silence splits a session into bursts" "[[1767261600, 1767262200], [1767268800, 1767268800]]" "$(val bursts)"
assert_eq "opencode's stamps read the same" "[[1767261600, 1767261660]]" "$(val millis)"
assert_eq "no stamps: no bursts" "[]" "$(val empty)"
assert_eq "two machines' copies join in order" "[[0, 400], [5000, 5000]]" "$(val joined)"

finish
