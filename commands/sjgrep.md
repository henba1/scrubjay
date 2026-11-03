---
description: scrubjay — keyword-search past sessions (one, a range, or all), show the hits in context, then pull one in or resume it
argument-hint: <what to look for, in plain words — e.g. "borg retention or prune on hennopi last month">
allowed-tools: Bash(bash:*), mcp__sjmcp__sj_get, mcp__sjmcp__sj_list, mcp__sjmcp__sj_recall, mcp__sjmcp__sj_search_within
---
The user wants to find **where specific words came up** across their archived sessions — one
session, a range of them, or all — see each hit in its context, and then pick a session (or a part
of one) to pull into this conversation or to resume.

Request: **$ARGUMENTS**

1. **Translate the request** into keywords and a scope. Say the translation in one line before
   running anything, so the user can correct it.
   - **Keywords**: the literal words that would appear in the text. Add obvious variants only — a
     plural, a spelling, a close synonym (`prune` + `pruning`, `retention` + `keep-daily`) — **five
     terms at most**. Matching is case-insensitive and literal: no regex, no wildcards. A
     multi-word phrase is one term (quote it). Prefer the distinctive word over the common one
     (`borg`, not `backup`).
   - **ANY or ALL**: default is ANY (a session needs one term; sessions hitting more terms rank
     first). Use `--all` only when the user plainly means *both* ("where we discussed X *and* Y").
   - **Scope**, the same vocabulary as `/sjtable`: `host=` `project=` `harness=` `model=`
     `topic=` `since=YYYY-MM-DD` `until=YYYY-MM-DD`; `head=N` = the newest N sessions in scope;
     `session=<sid8>[,<sid8>…]` (or bare 8-char ids) for specific sessions. Turn relative dates
     ("last month", "since the summer") into `since=`/`until=` from today's date. Leave the scope
     open when the user gave none — the search is fast.

2. **Run the search**:

   ```sh
   bash ~/.claude/hooks/../bin/sj-grep.sh [--all] [scope…] -- <term> "<multi word term>" …
   ```

   Put the terms after `--` so none is mistaken for a filter or a session id. Defaults: 10
   sessions, 3 snippets each, 2 lines of context (`--limit=N --max-snippets=N --context=N`).
   Exit codes: `0` hits · `1` no hits · `2` bad arguments · `3` no filesystem view of the
   archive (see the fallback below).
   - **No hits** → say so, then retry **once** with a broader set (drop `--all`, a shorter
     variant, a wider date range) before telling the user nothing matched.

3. **Present the candidates** compactly, best first: per session one line — `[n] sid8 · host ·
   project · date · topic — N hits (terms)` — then its snippets as the script printed them
   (turn #, line #, the «marked» hit). Trim, don't rewrite: keep the turn/line numbers exactly,
   they are what the next step slices by. If the script said it capped, say how many more there
   are and how to see them.

4. **Ask the user** which session — or which part of it — they want, and whether to:
   - **(a) pull it into context** — `sj_get(ref=<sid8>, turns="A-B")` for a range of turns,
     `lines="A-B"` for a passage, or the whole session condensed (`format="condensed"`, no
     slice). The numbers come straight from the snippet headers (`sj_get turns=… · lines=…`);
     widen a turn range by one or two either side when the user wants the surrounding
     conversation. Same rules as `/sjget`: a `lines=` slice wants `format="readable"`.
   - **(b) resume it** — follow `/sjresume`: run
     `bash ~/.claude/hooks/../bin/sj-resume.sh <sid8>` from the project directory on this
     machine (or with `--into <dir>`), relay its output — including any branch warning — and
     **relay the command it prints verbatim**; do not compose one yourself. A running session
     cannot become another one: staging is the whole job.

   Do not choose for them. Then do what they picked.

**Fallback — exit 3 (`no-archive`)**: this machine cannot read the archive as files (the
`rsync-wg` relay is write-only, or the NAS is not mounted). Search through sjmcp instead: pick
candidates with `sj_recall(query=<the terms, space-separated>, host=…, since=…)` (or `sj_list`
when the user named a host/date range rather than a topic), then call
`sj_search_within(ref=<sid8>, query=<one term>, context=2)` per candidate — `query` is **one
literal substring** per call, so loop over the terms. Present and ask exactly as above.

**Narrate as you go.** Before each tool call write one short line naming what you are about to do
and with what, e.g. `→ searching "borg", "prune" on hennopi since 2026-09-01`; after it, one
line with the outcome (`✓ 6 sessions hit, showing 6`, `✗ no filesystem archive — falling back to
sjmcp`). The user should see scrubjay working, not a silent pause.

Be concise. Do not dump raw tool JSON.
