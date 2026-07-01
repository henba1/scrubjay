---
description: dotclaude — pull a KNOWN archive item straight into context by id/path (no search); slice big transcripts
argument-hint: <sid8 | path | dc://uri> [turns=A-B | lines=A-B]
allowed-tools: mcp__dcmcp__dc_get
---
The user already knows exactly which archived item they want and is naming it directly —
so there is nothing to search or rank. The point of this command is minimal token usage:
one `dc_get`, no `dc_recall`, no candidate lists.

Ref + optional slice: **$ARGUMENTS**

1. Call `dc_get` **once** with `ref` = the id/path/URI the user gave (an 8-hex session id, a
   file path, or a `dc://` URI all work).
2. If the arguments include `turns=A-B` or `lines=A-B`, pass it straight through so only that
   slice is fetched — this is the whole reason to use `/dcget` over an `@`-mention on a large
   transcript. Pass `format=raw` only if the user asked for the raw `.jsonl`.
3. Do not call any other tool. Do not summarize or re-print the content — the `dc_get` result
   is already injected. If it errors (e.g. permission denied or unknown ref), report just that
   one line.

Tip: to pull a whole small doc with even less overhead, the user can `@`-mention it from the
`dcmcp` resource picker instead — no tool call at all.
