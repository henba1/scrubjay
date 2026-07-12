---
description: scrubjay — semantically recall a past session/plan/memory across all machines
argument-hint: <topic description> [host=… project=… since=YYYY-MM-DD]
allowed-tools: mcp__sjmcp__sj_recall, mcp__sjmcp__sj_get, mcp__sjmcp__sj_status
---
The user wants to find a past conversation, plan, or memory from the scrubjay archive by
describing its topic — not its filename or which machine it was on.

Topic / filters: **$ARGUMENTS**

1. Call `sj_recall` with the topic as `query` (pass `host` / `project` / `since` only if the user
   gave them). If it reports no archive reachable, say so (run `sj_status` to explain which trees
   this machine can see) and stop.
2. The tool returns candidate files with matched snippets + line anchors. **You** do the semantic
   ranking: read the snippets and pick the best match(es). Present the top 1–3 as a short list —
   topic, date, host, and why it matches (quote the telling snippet) — newest/most-relevant first.
3. Ask which one to pull in (or if the top hit is clearly the one, offer it). On the user's pick,
   call `sj_get` to inject it. For a long transcript, prefer a `turns=` or `lines=` slice around
   the relevant anchor rather than the whole file.

Be concise. Do not dump raw tool JSON; summarize.
