---
description: scrubjay — pull a KNOWN archive item straight into context by id/path (no search); slice big transcripts
argument-hint: <sid | path | sj://uri> [turns=A-B | lines=A-B] [full]
allowed-tools: mcp__sjmcp__sj_get
---
The user already knows exactly which archived item they want and is naming it directly —
so there is nothing to search or rank. The point of this command is minimal token usage:
one `sj_get`, no `sj_recall`, no candidate lists.

Ref + optional slice: **$ARGUMENTS**

1. Call `sj_get` **once** with `ref` = the id/path/URI the user gave. A session id works in
   either spelling — the 8-char handle or the whole `--resume` id.
2. **No slice named → the user wants the session, so fetch it condensed:** pass
   `format="condensed"`. It keeps every word of the conversation and folds the tool calls and
   tool output that make up about half the file, which is what gets a whole session into one
   call. Pass `format="readable"` instead when the tool traffic *is* the point (debugging what a
   command printed), or when the user says `full`; `format="raw"` only for the raw `.jsonl`.
3. **A slice was named** (`turns=A-B` / `lines=A-B`) → pass it straight through and leave the
   format `readable`: a targeted read wants the text verbatim, and a `lines=` number from
   `sj_recall` or `sj_search_within` indexes the readable file, not the condensed view.
4. Do not call any other tool. Do not summarize or re-print the content — the `sj_get` result
   is already injected. If it errors (e.g. permission denied or unknown ref), report just that
   one line.
5. Still `truncated`? The `hint` names the next slice. The user asked for the whole item, so
   follow it — but **stop after 3 fetches total**, then say in one line how much is left and let
   them ask. Raising `max_chars` is the last resort, not the reflex.

Tip: to pull a whole small doc with even less overhead, the user can `@`-mention it from the
`sjmcp` resource picker instead — no tool call at all.
