---
description: scrubjay — browse the archive (transcripts / plans / memories / notes) and pull one into context
argument-hint: [chats|transcript|plan|memory|note] [host=… project=… since=YYYY-MM-DD]
allowed-tools: mcp__sjmcp__sj_list, mcp__sjmcp__sj_get, mcp__sjmcp__sj_status
---
The user wants to browse the scrubjay archive and pull a chosen item into the session.

Selection / filters: **$ARGUMENTS**

1. If no type was given, default to **chats** — the cross-machine session overview — or take the one
   the user named: **chats**, **transcript**, **plan**, **memory**, or **note**.
2. Call `sj_list` with that type (use `type="log"` for **chats**) plus any `host` / `project` /
   `since` filters the user gave. Pass `limit=15` — a first page is meant to be read, not skimmed.
   If nothing is reachable, run `sj_status` and explain which trees this machine can see.
3. Render the page **once**, as a numbered list, in the order `sj_list` returned it. Keep it
   scannable — don't dump raw tool JSON, and don't re-type fields the row already shows:
   - **chats**: `date · host · topic`.
   - **transcript / plan / memory / note**: `date · host · project · topic`. Notes are
     cross-machine, so they have no host — show `project` instead.

   Then state the total and offer the rest: the result carries `total`, and `next_offset`/`more`
   when there is more. "*15 of 114 — say more for the next page*" is the whole line.
4. Follow-ups are arguments, not a second full fetch:
   - more rows → `sj_list(..., offset=<next_offset>)`;
   - a different order → `sort="size"|"turns"|"host"|"date"` with `order="asc"|"desc"`;
   - the user asks about `cwd`, harness, model or size → `fields="full"` for that one call.
5. On the user's pick, call `sj_get` to inject it — for a **chats** row, pass its `sid`; slice a long
   transcript with `turns=`/`lines=`. `sj_get` caps its content: if the result comes back
   `truncated`, follow the `hint` it gives (or narrow with `sj_search_within` first) rather than
   re-fetching with a bigger `max_chars`. A chats row whose transcript never reached this machine is
   a pointer only: `sj_get` answers `"no transcript in this archive"` with the `host` that has it —
   relay that ("look on `<host>`") instead of retrying.

Tip: transcripts/plans/memories/notes are also available as `@`-mention resources (the `sjmcp` resource
picker), if the user would rather attach one directly. Be concise.
