---
description: scrubjay — browse the archive (transcripts / plans / memories) and pull one into context
argument-hint: [transcript|plan|memory] [host=… project=… since=YYYY-MM-DD]
allowed-tools: mcp__sjmcp__sj_list, mcp__sjmcp__sj_get, mcp__sjmcp__sj_status
---
The user wants to browse the scrubjay archive and pull a chosen item into the session.

Selection / filters: **$ARGUMENTS**

1. If no type was given, ask which: **transcript**, **plan**, or **memory** (one line).
2. Call `sj_list` with that `type` and any `host` / `project` / `since` filters the user gave
   (default `limit` is fine). If nothing is reachable, run `sj_status` and explain which trees this
   machine can see.
3. Present the results as a compact, **date-sorted** numbered list: date · host · project · topic
   (and turns/size where useful). Keep it scannable.
4. On the user's pick, call `sj_get` to inject it (slice a long transcript with `turns=`/`lines=`).

Tip: the same items are also available as `@`-mention resources (the `sjmcp` resource picker), if
the user would rather attach one directly. Be concise; don't dump raw tool JSON.
