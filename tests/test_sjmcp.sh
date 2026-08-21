#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# sjmcp result budgets — what sj_list and sj_get are allowed to spend of the caller's context.
#
# Both tools used to return whatever the archive happened to hold: sj_list a fixed verbose row per
# result with no sort and no offset (#69), sj_get an entire transcript (#50, a 153K response the
# client refused outright). The contract these tests pin is not "smaller" but *bounded and honest*:
# a result that was trimmed says it was trimmed, says how much is left, and names the exact
# argument that fetches the rest — and every bound is a parameter with an env override, so nothing
# here is a constant a caller is stuck with.
#
# Exercised through the core_* functions rather than an MCP handshake: they are what the tool
# wrappers call, and importing the module needs nothing beyond the stdlib (the `mcp` dependency is
# imported lazily inside build_server). So this runs on a bare CI box with no `uv` resolve.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

SERVER="$APP/mcp/sjmcp_server.py"

if ! need_cmd python3 "sjmcp result budgets"; then finish; exit; fi

# ── the fixture ────────────────────────────────────────────────────────────────────────────────
# 60 catalogue rows on two hosts with varying turns/size, plus three readable transcripts — one of
# them far over any sane cap, which is the #50 case.
LOGS="$SCRUBJAY_DATA/logs"; mkdir -p "$LOGS"
: > "$LOGS/hostpi.log"
i=0
while [ "$i" -lt 60 ]; do
  host=hostpi; [ $((i % 2)) -eq 0 ] || host=laptop
  printf '2026-0%d-%02d %02d:%02d | %s | /home/u/code/dotclaude | "topic number %d about the energy tab" | session=%08x-1111-2222-3333-444444444444 | harness=claude | model=claude-opus-4 | turns=%d | size=%d\n' \
    $((1 + i % 9)) $((1 + i % 28)) $((i % 24)) $((i % 60)) "$host" "$i" "$i" "$((i * 3))" "$((i * 40000 + 500))" \
    >> "$LOGS/hostpi.log"
  i=$((i + 1))
done

RD="$SCRUBJAY_LOCAL_CHATS/hostpi/readable/dotclaude"; mkdir -p "$RD"
printf '# t\n_4 turns_\n## User\nshort and sweet\n' > "$RD/2026-08-01_a-small-one__aaaa0001.md"
# A transcript shaped like a real render: prose, tool calls with long output, and one fenced block
# the *assistant* wrote — which condensing must leave alone.
{ printf '# t\n_2 turns_\n\n## User\n\nwhat does the log say\n\n## Assistant\n\n'
  printf 'here is what I ran\n\n**\xe2\x86\x92 Bash**\n\n```bash\ngrep -n boom /var/log/syslog\n```\n\n'
  printf '**\xe2\x8e\xbf output:**\n\n```text\n'
  i=0; while [ "$i" -lt 300 ]; do printf 'syslog line %d — noise noise noise\n' "$i"; i=$((i + 1)); done
  printf '```\n\nand the fix is\n\n```python\nassistant_wrote_this = 1\nsecond_line = 2\nthird_line = 3\n```\n'
} > "$RD/2026-08-03_a-tooly-one__aaaa0003.md"
# A memory: no turns, no tool blocks — and a fenced block that is the content itself.
MEM="$SCRUBJAY_LOCAL_CHATS/memory/dotclaude"; mkdir -p "$MEM"
printf 'the shim to use\n\n```sh\nsj_mtime() { :; }\nsecond_line=2\nthird_line=3\n```\n' \
  > "$MEM/portability-shims.md"
{ printf '# t\n_120 turns_\n'; i=0; while [ "$i" -lt 4000 ]; do
    printf '## User\nline %d — lorem ipsum dolor sit amet consectetur adipiscing\n' "$i"; i=$((i + 1)); done
} > "$RD/2026-08-02_a-big-one__aaaa0002.md"

OUT="$SANDBOX/probe.json"
SJ_SERVER="$SERVER" python3 - "$OUT" <<'PY'
import importlib.util, json, os, sys

spec = importlib.util.spec_from_file_location("sjmcp_server", os.environ["SJ_SERVER"])
m = importlib.util.module_from_spec(spec)
sys.modules["sjmcp_server"] = m          # dataclasses resolve annotations through sys.modules
spec.loader.exec_module(m)

def chars(o):
    return len(json.dumps(o, ensure_ascii=False))

big = [a for a in m._all_artifacts(m.roots()) if a.sid == "aaaa0002"][0].path
small = [a for a in m._all_artifacts(m.roots()) if a.sid == "aaaa0001"][0].path

default = m.core_list(type="log")
full = m.core_list(type="log", limit=20, fields="full")
page2 = m.core_list(type="log", limit=20, offset=20)
last = m.core_list(type="log", limit=20, offset=40)
allrows = m.core_list(type="log", limit=0, max_chars=0)
capped = m.core_list(type="log", limit=60, fields="full", max_chars=2000)
uncapped = m.core_list(type="log", limit=60, fields="full", max_chars=0)
bysize = m.core_list(type="log", limit=3, sort="size")
byturns = m.core_list(type="log", limit=3, sort="turns", order="asc")
bogus = m.core_list(type="log", limit=3, sort="nonsense")
mixed = m.core_list(limit=5)                       # no type filter → the type stays on the row

get = m.core_get(big)
# Feed the hint's own suggestion back in: the next slice must start exactly where this one stopped.
nxt = int(get["hint"].split("Continue with lines='")[1].split("-")[0])
follow = m.core_get(big, lines=f"{nxt}-{nxt + 20}")
first_after = follow["content"].splitlines()[1]
tail_of_head = get["content"].splitlines()[-1]
whole = m.core_get(big, max_chars=0)

os.environ["SJMCP_GET_MAX_CHARS"] = "5000"
env_get = m.core_get(big)
os.environ["SJMCP_LIST_MAX_CHARS"] = "900"
env_list = m.core_list(type="log", limit=60)
del os.environ["SJMCP_GET_MAX_CHARS"], os.environ["SJMCP_LIST_MAX_CHARS"]

# The same session, named three ways: the handle the other tools print, the whole UUID a user
# pastes from `claude --resume`, and opencode's `ses_`-prefixed spelling of the same handle.
by_handle = m.core_get("aaaa0003")
by_uuid = m.core_get("aaaa0003-1111-2222-3333-444444444444")
by_ses = m.core_get("ses_aaaa0003zzzz")
readable = m.core_get("aaaa0003", max_chars=0)
condensed = m.core_get("aaaa0003", format="condensed")
mem = [a for a in m._all_artifacts(m.roots()) if a.type == "memory"][0].path
cond_mem = m.core_get(mem, format="condensed")
os.environ["SJMCP_GET_CONDENSED_MAX_CHARS"] = "200"
cond_env = m.core_get("aaaa0003", format="condensed")
del os.environ["SJMCP_GET_CONDENSED_MAX_CHARS"]

json.dump({
    "default_limit": default["shown"], "total": default["total"],
    "default_keys": sorted(default["items"][0]),
    "full_keys": sorted(full["items"][0]),
    "compact_chars": chars(default), "full_chars": chars(full),
    "sort_label": default["sort"], "next_offset": default.get("next_offset"),
    "more": default.get("more", ""),
    "page2_first_sid": page2["items"][0]["sid"],
    "row21_sid": allrows["items"][20]["sid"],
    "last_has_next": "next_offset" in last, "last_offset": last["offset"],
    "capped_shown": capped["shown"], "capped_says": capped.get("capped", ""),
    "uncapped_shown": uncapped["shown"], "uncapped_says": uncapped.get("capped", ""),
    "size_desc": [r["size"] for r in bysize["items"]],
    "turns_asc": [r["turns"] for r in byturns["items"]],
    "bogus_sort": bogus["sort"],
    "mixed_type": mixed["items"][0].get("type", ""),
    "get_truncated": get.get("truncated", False), "get_chars": len(get["content"]),
    "get_total_lines": get["total_lines"], "get_total_turns": get.get("total_turns"),
    "get_hint": get["hint"], "get_ends_clean": get["content"].endswith("\n"),
    "resume_is_contiguous": first_after != tail_of_head and follow["content"].count("\n") > 1,
    "resume_line": nxt, "whole_chars": len(whole["content"]),
    "whole_truncated": "truncated" in whole,
    "small_truncated": "truncated" in m.core_get(small),
    "env_get_chars": len(env_get["content"]), "env_list_chars": chars(env_list),
    "by_handle_path": by_handle.get("path", ""), "by_uuid_path": by_uuid.get("path", ""),
    "by_ses_path": by_ses.get("path", ""),
    "readable_chars": len(readable["content"]),
    "cond_chars": len(condensed["content"]),
    "cond_truncated": "truncated" in condensed,
    "cond_format": condensed["format"], "cond_elided": condensed.get("elided", ""),
    "cond_keeps_command": "grep -n boom /var/log/syslog" in condensed["content"],
    "cond_keeps_prose": "and the fix is" in condensed["content"],
    "cond_keeps_own_fence": "third_line = 3" in condensed["content"],
    "cond_drops_output": "syslog line 299" in condensed["content"],
    "cond_says_how_much": "elided" in condensed["content"],
    "cond_mem_format": cond_mem["format"], "cond_mem_elided": cond_mem.get("elided", ""),
    "cond_mem_intact": "third_line=3" in cond_mem["content"],
    "cond_env_chars": len(cond_env["content"]), "cond_env_truncated": "truncated" in cond_env,
}, open(sys.argv[1], "w"), indent=1)
PY
rc=$?
check "the probe ran" test "$rc" = 0
[ "$rc" = 0 ] || { finish; exit; }
j() { jq -r "$1" "$OUT"; }

# ── sj_list: the page is a page, and says what is off the end of it ────────────────────────────
# 50 was never a page size anyone chose; it was the number a browse happened to cost. A default
# small enough to read, plus an offset, is what makes "show me more" cheaper than re-listing.
section "sj_list pages instead of dumping"
assert_eq "the default page is 20 rows, not the whole catalogue" "20" "$(j .default_limit)"
assert_eq "the full count is still reported" "60" "$(j .total)"
assert_eq "a page that has a successor says where it is" "20" "$(j .next_offset)"
assert_contains "and says how many are left, in words a caller can act on" "$(j .more)" "offset=20"
assert_eq "offset=20 starts exactly where the first page stopped" "$(j .row21_sid)" "$(j .page2_first_sid)"
assert_eq "the last page advertises no successor" "false" "$(j .last_has_next)"
assert_eq "and echoes the offset it was asked for" "40" "$(j .last_offset)"

# ── sj_list: the compact row ───────────────────────────────────────────────────────────────────
# cwd is `…/<project>` and project is already on the row; harness/model are constant down a page.
# Dropping them is most of the win, so the shape is pinned rather than left to drift back.
section "the compact row drops what the caller can already infer"
compact_keys="$(j '.default_keys | join(",")')"
assert_eq "compact is date/host/project/sid/time/topic" "date,host,project,sid,time,topic" "$compact_keys"
check "compact carries no cwd" bash -c '! grep -q cwd <<<"$1"' _ "$compact_keys"
check "compact carries no harness or model" bash -c '! grep -qE "harness|model" <<<"$1"' _ "$compact_keys"
assert_contains "fields=full brings cwd back" "$(j '.full_keys | join(",")')" "cwd"
assert_contains "fields=full brings harness back" "$(j '.full_keys | join(",")')" "harness"
# The type filter is an argument the caller just passed; echoing it back per row is pure cost.
assert_eq "a type-filtered row does not echo the filter" "" "$(j '.default_keys | index("type") // ""')"
assert_eq "an unfiltered list still names each row's type" "transcript" "$(j .mixed_type)"
# Same 20 rows, both shapes — the only variable is the row.
check "a compact page is materially smaller than a full one" \
  bash -c '[ "$1" -lt "$(( $2 * 3 / 4 ))" ]' _ "$(j .compact_chars)" "$(j .full_chars)"

# ── sj_list: sort ──────────────────────────────────────────────────────────────────────────────
section "sj_list sorts server-side"
assert_eq "the applied sort is reported, not assumed" "date desc" "$(j .sort_label)"
assert_eq "sort=size is descending by real magnitude, not string order" \
  "2.3 MB" "$(j '.size_desc[0]')"
assert_eq "and the next one down really is smaller" "2.2 MB" "$(j '.size_desc[1]')"
# Ordering a page by a column the page does not show reads as unsorted and gets re-fetched.
check "the sorted-on column is visible even in compact" bash -c '[ -n "$1" ]' _ "$(j '.size_desc[0]')"
assert_eq "sort=turns order=asc starts at the smallest" "0" "$(j '.turns_asc[0]')"
assert_eq "and counts turns numerically, not lexically" "3" "$(j '.turns_asc[1]')"
assert_eq "an unknown sort key degrades to the default, not an error" "date desc" "$(j .bogus_sort)"

# ── sj_list: the byte budget ───────────────────────────────────────────────────────────────────
section "sj_list holds a byte budget and admits when it bites"
check "max_chars drops rows rather than overrunning" \
  bash -c '[ "$1" -lt 60 ] && [ "$1" -gt 0 ]' _ "$(j .capped_shown)"
assert_contains "and says it capped" "$(j .capped_says)" "capped at 2000 chars"
assert_contains "naming both ways out" "$(j .capped_says)" "max_chars"
assert_eq "max_chars=0 is an explicit opt-out" "60" "$(j .uncapped_shown)"
assert_eq "which stays silent about capping" "" "$(j .uncapped_says)"
# The budget covers the whole result, envelope included — not just the rows inside it.
check "SJMCP_LIST_MAX_CHARS overrides the default, and bounds the whole result" \
  bash -c '[ "$1" -le 900 ]' _ "$(j .env_list_chars)"

# ── sj_get: the content cap ────────────────────────────────────────────────────────────────────
# #50: a 153K response the client would not accept, dumped to a file as one JSON-escaped line.
section "sj_get caps content and points at the next slice"
assert_eq "an oversized artifact comes back truncated" "true" "$(j .get_truncated)"
check "under the default 24000-char budget" bash -c '[ "$1" -le 24000 ]' _ "$(j .get_chars)"
check "and the file really was bigger than that" bash -c '[ "$1" -gt 100000 ]' _ "$(j .whole_chars)"
assert_eq "the cut lands on a line boundary, never mid-line" "true" "$(j .get_ends_clean)"
assert_eq "the total line count is reported so the caller can aim" "8002" "$(j .get_total_lines)"
assert_eq "so is the turn count, for turns= slicing" "4000" "$(j .get_total_turns)"
assert_contains "the hint names a concrete next slice" "$(j .get_hint)" "Continue with lines='"
assert_contains "offers the cheaper search-first route" "$(j .get_hint)" "sj_search_within"
assert_contains "and says the cap itself is raisable" "$(j .get_hint)" "max_chars"
# The hint is only useful if following it literally works.
assert_eq "following the hint resumes where the head stopped" "true" "$(j .resume_is_contiguous)"
assert_eq "max_chars=0 still returns the whole file" "false" "$(j .whole_truncated)"
assert_eq "a small artifact is untouched — no cap noise on the common case" "false" "$(j .small_truncated)"
check "SJMCP_GET_MAX_CHARS overrides the default" \
  bash -c '[ "$1" -le 5000 ]' _ "$(j .env_get_chars)"

# ── sj_get: a session id in whatever spelling the user has ─────────────────────────────────────
# A whole id used to miss the sid branch, fall through to the path branch, and come back as
# "no transcript in this archive" — which names another host, so a session sitting right there
# read as one that had never been relayed.
section "sj_get resolves a session id in either spelling"
assert_eq "the 8-char handle resolves" "false" "$(j '.by_handle_path == ""')"
assert_eq "the whole UUID resolves to the same file" "$(j .by_handle_path)" "$(j .by_uuid_path)"
assert_eq "and so does opencode's ses_ spelling" "$(j .by_handle_path)" "$(j .by_ses_path)"

# ── sj_get: condensed ──────────────────────────────────────────────────────────────────────────
# Tool traffic is most of a transcript's weight and none of its argument. Folding it is what puts
# a whole session in one fetch — so the test is that the *conversation* survives intact.
section "format=condensed folds tool traffic, not the conversation"
assert_eq "it says which format it returned" "condensed" "$(j .cond_format)"
check "and it is materially smaller than the readable file" \
  bash -c '[ "$1" -lt "$(( $2 / 2 ))" ]' _ "$(j .cond_chars)" "$(j .readable_chars)"
assert_eq "the tool call itself is kept — you can see what ran" "true" "$(j .cond_keeps_command)"
assert_eq "its 300 lines of output are not" "false" "$(j .cond_drops_output)"
assert_eq "the elision is visible in the text, not silent" "true" "$(j .cond_says_how_much)"
assert_contains "and the result says how to get the full text back" "$(j .cond_elided)" "format='readable'"
assert_contains "warning that its line numbers are its own" "$(j .cond_elided)" "condensed view"
assert_eq "assistant prose is untouched" "true" "$(j .cond_keeps_prose)"
# The marker is what makes a block tool output; a fence the assistant wrote has none.
assert_eq "so is a code block the assistant wrote itself" "true" "$(j .cond_keeps_own_fence)"
assert_eq "a session that fits arrives whole, in one call" "false" "$(j .cond_truncated)"
# Condensed is the "read the whole thing" format, so it pages at its own, larger budget.
check "SJMCP_GET_CONDENSED_MAX_CHARS overrides that budget" \
  bash -c '[ "$1" -le 200 ]' _ "$(j .cond_env_chars)"
assert_eq "and a condensed result that still overran says so" "true" "$(j .cond_env_truncated)"
# Memories and notes have no tool blocks; clipping a fence there would silently eat the content.
assert_eq "condensing a non-transcript is a no-op..." "readable" "$(j .cond_mem_format)"
assert_eq "...that does not claim to have elided anything" "" "$(j .cond_mem_elided)"
assert_eq "...and leaves its code block whole" "true" "$(j .cond_mem_intact)"

finish
