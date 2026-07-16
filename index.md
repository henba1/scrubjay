# scrubjay

The **app/logic** for syncing [Claude Code](https://claude.ai/code) across machines. Your personal content is kept in *separate* repos so this one can be shared/public without leaking anything:

| Repo                | Role                                                                  | Visibility  |
| ------------------- | --------------------------------------------------------------------- | ----------- |
| **scrubjay** (this) | scripts, hooks, docs — the logic                                      | public-able |
| **scrubjay-data**   | `hosts/`, `settings/`, `claude-md/`, `templates/`, `memory/`, `logs/` | private     |
| **scrubjay-chats**  | full chat transcripts (`.jsonl`), relayed off each machine            | private     |

Diagram source: [`overview.dot`](https://henba1.github.io/scrubjay/overview.dot) — `dot -Tsvg docs/overview.dot -o docs/overview.svg`.

> **Flow:** `scrubjay` (logic) + `scrubjay-data` (your config) → applied into each machine's `~/.claude` by `claude-sync.sh`. On `SessionEnd` a hook appends a one-line entry to `scrubjay-data/logs/<host>.log` *and* relays the session (transcript, subagents, plans) off the machine via a pluggable backend — either peer-to-peer to your own NAS (over WireGuard), or to a private `scrubjay-chats` repo on GitHub if you'd rather not run storage of your own. Top-level is keyed by machine so envs stay distinct and Claude can re-tailor one host's rules for another.

## Where to go

- **[Concepts](https://henba1.github.io/scrubjay/concepts/index.md)** — the two-kinds-of-sync model, what scrubjay is, and what lives in the database. Start here to understand *why* the system is shaped this way.
- **[Onboarding](https://henba1.github.io/scrubjay/onboarding/index.md)** — install on a new machine (interactive script or Claude-assisted), the repo layout, and the machine-local pointers.
- **[Day-to-day](https://henba1.github.io/scrubjay/day-to-day/index.md)** — the hooks that keep it hands-off, finding a past chat, and troubleshooting.
- **[Query the archive (MCP)](https://henba1.github.io/scrubjay/archive-mcp/index.md)** — recall a past session by *topic* from inside a live Claude session via the read-only `sjmcp` server.
- **[Slash commands](https://henba1.github.io/scrubjay/slash-commands/index.md)** — the `/sj*` command reference.
- **[Transcripts: relay + NAS](https://henba1.github.io/scrubjay/transports/index.md)** — how sessions ride peer-to-peer to your own NAS, and the two P2P paths (WireGuard / SSH).
- **[Reference](https://henba1.github.io/scrubjay/reference/index.md)** — the by-hand command cheatsheet and environment toggles.
