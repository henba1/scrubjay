# Slash commands

All scrubjay commands live in `commands/*.md` and are symlinked into `~/.claude/commands/` by
`claude-sync.sh`, so they're available in every session as `/<name>`. Because they ship with the
**app** (not your private data repo), every machine that installs scrubjay gets them out of the
box. They fall into two groups: **archive/recall** commands are thin wrappers that drive the
read-only [`sjmcp` MCP tools](archive-mcp.md); **lifecycle** commands just run the same scripts the
`SessionStart`/`SessionEnd` hooks do, on demand.

## Archive & recall (drive the `sjmcp` tools)

| Command | Calls under the hood | Typically useful for |
|---|---|---|
| `/sjrecall <topic> [host= project= since=]` | `sj_recall` → `sj_get` | *"I discussed X somewhere, ages ago — which machine even?"* Semantic recall across **all** machines: ranks candidates by topic, then pulls the one you pick (or a slice) into context. Start here when you remember the gist but not the where/when. |
| `/sjbrowse [transcript\|plan\|memory] [host= project= since=]` | `sj_list` → `sj_get` | Eyeballing a **date-sorted list** and grabbing one, when you have no search term in mind — "show me the last few plans on `laptop`." |
| `/sjfind <topic> in <session-id\|topic-words> [context=N]` | `sj_search_within` (+ `sj_recall`/`sj_get`) | You know **which** session and want the **exact spot** a subject came up — returns turn/line anchors inside that one transcript instead of the whole thing. |
| `/sjget <sid8 \| path \| sj://uri> [turns=A-B \| lines=A-B]` | `sj_get` (one call, no search) | You **already know the item** and just want it pulled in — cheapest way, no recall/ranking. Its edge is **slicing**: fetch only `lines=1200-1300` or `turns=5-10` of a huge transcript to keep tokens down. |

> For pulling a *whole small* doc with even less overhead than `/sjget`, `@`-mention it from the
> `sjmcp` resource picker (match on the title, e.g. `plan: … — <date> · <host>`) — the harness
> injects it directly with no tool call at all.

## Lifecycle & sync (run the hook scripts on demand)

| Command | Mirrors | Does |
|---|---|---|
| `/sjsync` | SessionStart | Pull the data repo + cross-machine memory, then re-apply config into `~/.claude`. Grab changes another machine just pushed, mid-session, instead of waiting for the next start. |
| `/sjlog` | SessionEnd | Publish *now* without ending the session: log line + chats index + push data repo + push memory + relay this session's transcript/plans/history/tasks to the NAS. Handy so another machine (or `/sjrecall`) can see it right away. |
| `/sjonboard [hint]` | — | Guided wrapper around `bin/onboard.sh` (gathers choices in chat, then runs it unattended). For onboarding or reconfiguring (e.g. *"switch backend to rsync-wg"*). For a *brand-new* machine without scrubjay yet, run `bin/onboard.sh` in a terminal instead. |
| `/sjmemory` | — | Enable/repair cross-machine memory on **this** machine (idempotent — runs `bin/onboard-memory.sh`). First-time memory setup, or when memory sync looks broken. |
