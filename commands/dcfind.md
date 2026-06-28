---
description: dotclaude — find where a topic appears *within* a past session/plan/memory
argument-hint: <topic> in <session-id|topic-words> [context=N]
allowed-tools: mcp__dcmcp__dc_recall, mcp__dcmcp__dc_search_within, mcp__dcmcp__dc_get
---
The user wants the spot(s) inside one specific archived conversation/plan/memory where a topic is
discussed — the "jump me to where we talked about X" case.

Request: **$ARGUMENTS**  (typically "<topic> in <which session>")

1. Identify the target file. If the user named a session id (8 hex) or a `dc://…` URI, use it
   directly as `ref`. Otherwise call `dc_recall` on the "in <…>" part to locate the session, and
   confirm the match with the user if ambiguous.
2. Call `dc_search_within(ref, query=<the topic>, context=N)`. It returns passages with **line
   anchors and the enclosing turn number**.
3. Present the matches as a short ordered list: turn #, line #, and the excerpt. If there are many,
   summarize where the discussion is densest.
4. Offer to `dc_get` a `turns=` / `lines=` slice around the best hit to pull it into context.

Be concise. Do not dump raw tool JSON.
