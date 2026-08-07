---
description: scrubjay — show the chat catalogue as a table (filter + slice, pandas-style)
argument-hint: "[head=N|tail=N|[a:b]|all] [host= project= harness= model= topic= since= until=]"
allowed-tools: Bash(bash:*), Bash(echo:*)
---
!`bash "$(cd -P "$(dirname "$(readlink ~/.claude/hooks/sync-session.sh || echo ~/.claude/hooks/sync-session.sh)")/.." && pwd)/bin/sj-table.sh" $ARGUMENTS </dev/null 2>&1; echo "exit: $?"`

The user wants their cross-machine chat catalogue as a **human-readable table**. The script above
already ran and its output is the answer.

**Print that table verbatim.** It is aligned Markdown, built to be read raw — do not re-render,
re-sort, summarize, or "improve" it. Reformatting it costs tokens and loses the alignment. Add at
most one short line of your own if something needs saying.

Filters are applied **before** slices, so `harness=opencode head=20` means *the newest 20 opencode
sessions* — one question, not two. Available: `head=N`, `tail=N`, `[a:b]` (0-based, newest-first,
end exclusive), `all`, and `host= project= harness= model= topic= since= until=`.

With no arguments it prints a one-line summary and the catalogue's path rather than ~600 rows —
**deliberate, not a failure.** A filter alone prints its matches (capped, and it says when it
capped). If the user clearly wants rows but named no bound, suggest the narrowing that fits what
they asked — `head=20`, a `harness=`/`host=` filter, `since=` — rather than reaching for `all`.

Blank `Topic` cells are expected: only the `/sjlog` path has a model in the loop to author one, so
an ordinary SessionEnd leaves it empty. The row is still a real, resumable session — unlike
`/sjbrowse`, this table does not hide them. Blank `Harness`/`Model`/`Turns`/`Size` mean the row
predates those fields (added 2026-07-14 and -15).

To pull a listed session into context, use its **Session** id: `/sjget <id>`, or `/sjresume <id>`
to continue it on this machine.
