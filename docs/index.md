# dotclaude

The **app/logic** for syncing [Claude Code](https://claude.ai/code) across machines.
Your personal content is kept in *separate* repos so this one can be shared/public
without leaking anything:

| Repo | Role | Visibility |
|---|---|---|
| **dotclaude** (this) | scripts, hooks, docs — the logic | public-able |
| **dotclaude-data** | `hosts/`, `settings/`, `claude-md/`, `templates/`, `memory/`, `logs/` | private |
| **claude-chats** | full chat transcripts (`.jsonl`), relayed off each machine | private |

![dotclaude — system overview](overview.svg)

<sub>Diagram source: [`overview.dot`](overview.dot) — `dot -Tsvg docs/overview.dot -o docs/overview.svg`.</sub>

> **Flow:** `dotclaude` (logic) + `dotclaude-data` (your config) → applied into each
> machine's `~/.claude` by `claude-sync.sh`. On `SessionEnd` a hook appends a one-line
> entry to `dotclaude-data/logs/<host>.log` *and* relays the session (transcript,
> subagents, plans) to the NAS via a pluggable backend — peer-to-peer over WireGuard, or
> `claude-chats` on GitHub as a stopgap. Top-level is keyed by machine so envs stay
> distinct and Claude can re-tailor one host's rules for another.

## Where to go

- **[Concepts](concepts.md)** — the two-kinds-of-sync model, what dotclaude is, and
  what lives in the database. Start here to understand *why* the system is shaped this way.
- **[Onboarding](onboarding.md)** — install on a new machine (interactive script or
  Claude-assisted), the repo layout, and the machine-local pointers.
- **[Day-to-day](day-to-day.md)** — the hooks that keep it hands-off, finding a past
  chat, and troubleshooting.
- **[Query the archive (MCP)](archive-mcp.md)** — recall a past session by *topic* from
  inside a live Claude session via the read-only `dcmcp` server.
- **[Slash commands](slash-commands.md)** — the `/dc*` command reference.
- **[Transcripts: relay + NAS](transports.md)** — how sessions ride peer-to-peer to
  your own NAS, and the two P2P paths (WireGuard / SSH).
- **[Reference](reference.md)** — the by-hand command cheatsheet and environment toggles.
