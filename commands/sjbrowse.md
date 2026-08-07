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
   `since` filters the user gave (default `limit` is fine). If nothing is reachable, run `sj_status`
   and explain which trees this machine can see.
3. Present the results as a compact, **date-sorted** numbered list. Keep it scannable — don't dump
   raw tool JSON:
   - **chats**: `date · host · harness+model · topic · size` (this is the overview the user asked
     for; drop `harness+model`/`size` for a row that predates them rather than showing blanks).
   - **transcript / plan / memory / note**: `date · host · project · topic` (turns/size where
     useful). Notes are cross-machine, so they have no host — show `project` instead.
4. On the user's pick, call `sj_get` to inject it — for a **chats** row, pass its `sid`; slice a long
   transcript with `turns=`/`lines=`. A chats row whose transcript never reached this machine is a
   pointer only ("look on <host>"): say so instead of trying to fetch it.

Tip: transcripts/plans/memories/notes are also available as `@`-mention resources (the `sjmcp` resource
picker), if the user would rather attach one directly. Be concise.
