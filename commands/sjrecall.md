---
description: scrubjay — semantically recall a past session/plan/memory/note across all machines
argument-hint: <topic description> [host=… project=… since=YYYY-MM-DD]
allowed-tools: mcp__sjmcp__sj_recall, mcp__sjmcp__sj_get, mcp__sjmcp__sj_status
---
The user wants to find a past conversation, plan, memory, or note from the scrubjay archive by
describing its topic — not its filename or which machine it was on.

Topic / filters: **$ARGUMENTS**

1. Call `sj_recall` with the topic as `query` (pass `host` / `project` / `since` only if the user
   gave them). If it reports no archive reachable, say so (run `sj_status` to explain which trees
   this machine can see) and stop.
2. The tool returns candidate files with matched snippets + line anchors. **You** do the semantic
   ranking: read the snippets and pick the best match(es) — `score` is a lexical shortlist, not a
   verdict. Present the top 1–3 as a short list — topic, date, host, and why it matches (quote the
   telling snippet) — newest/most-relevant first. A `type=log` hit has no transcript on this
   machine: offer it as a "you had this on `<host>`" pointer, don't try to `sj_get` it.
3. Ask which one to pull in (or if the top hit is clearly the one, offer it). On the user's pick,
   call `sj_get` — and for a long transcript **slice it**: a snippet's `line` is a line number in
   the same file, so `lines=<line-20>-<line+20>` fetches the matching passage. Fetch the whole
   file only when the user wants the whole session.

**Narrate as you go.** Before each tool call write one short line naming what you are about to do
and with what, e.g. `→ recalling "retry backoff" across all hosts since 2026-09-01`; after it, one
line with the outcome (`✓ 6 candidates from 3 hosts`, `✗ archive unreachable`). The user should
see scrubjay working, not a silent pause.

Be concise. Do not dump raw tool JSON; summarize.
