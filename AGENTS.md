# AGENTS.md — guidance for coding agents in this repo

This file is for AI coding agents (Claude Code, Cursor, etc.) working in **dotclaude**.
Humans should start at [`README.md`](README.md) and the docs site.

## What this repo is

dotclaude is the **app/logic** for syncing [Claude Code](https://claude.ai/code) across
machines: a git-based config sync plus a pluggable, peer-to-peer transcript relay to the
user's own NAS. It is one of three repos — this one holds **only machinery** and is
public-safe; the user's actual content lives in two *private* sibling repos that are **not**
in this checkout:

| Repo | Role |
|---|---|
| **dotclaude** (this) | scripts, hooks, docs — the logic |
| **dotclaude-data** | `hosts/`, `settings/`, `claude-md/`, `templates/`, `memory/`, `logs/` |
| **claude-chats** | full chat transcripts (`.jsonl`), relayed off each machine |

Read [`docs/concepts.md`](docs/concepts.md) for the design (the "author-vs-record picks
git-vs-rsync; sensitive-vs-not picks NAS-vs-GitHub" model). Full docs build with MkDocs
(`docs/`, `mkdocs.yml`).

## Repo map

- `bin/` — the shell logic. Entry point for setup is `bin/onboard.sh`; `bin/lib.sh` holds
  shared helpers; `bin/claude-sync.sh` applies data-repo config into `~/.claude`.
- `hooks/` — `sync-session.sh` (SessionStart), `log-session.sh` (SessionEnd), and
  `transports/<backend>.sh` (`git` / `rsync-wg` / `local`).
- `mcp/dcmcp_server.py` — the read-only archive MCP server (`uv run --script`).
- `commands/` — the generic `/dc*` slash commands shipped with the app.
- `skeleton/host/` — template copied when registering a new machine.
- `docs/` — the documentation site (also the source for the published site + `llms.txt`).

## Assisted install — onboarding a new machine

A common reason a user opens you here is *"set up dotclaude on this machine."* Drive
`bin/onboard.sh` for them — it is interactive, but every prompt honors a preset env var, so
you can gather the choices in chat and run it unattended. (This mirrors the `/dconboard`
command in `commands/dconboard.md`, which only exists *after* install — on a fresh clone you
are the front-end.)

Steps:

1. **Gather choices in chat:** stable host name; relay backend (`rsync-wg` / `local` / `git`
   / `off` — present them as peer options, no default) and its settings — for `rsync-wg`/`git` the receiver `user` / `host` /
   `port` / rrsync-`path`; for `local` the NAS mount path; and whether to enable
   cross-machine memory.
2. **Confirm, then run non-interactively** from the clone, e.g.:

   ```sh
   DOTCLAUDE_HOST=<host> DOTCLAUDE_BACKEND=<backend> \
   RECV_USER=<user> RECV_HOST=<host-or-ip> RECV_PORT=<port> RECV_PATH=<rrsync-root> \
   bash ./bin/onboard.sh </dev/null
   ```

   (Omit the `RECV_*` for `local`/`off`; use `LOCAL_CHATS=<path>` for `local`.)
3. **Report what changed** and surface the manual step below.

### ⚠️ The one step you must NOT do for the user

For the peer-to-peer backends, `onboard.sh` (and `onboard-memory.sh`) **print an
`authorized_keys` line**. That line must be pasted into the **receiver** account's
`~/.ssh/authorized_keys` **by a human with root on the receiver** — this is a deliberate
anti-self-authorization design: a new machine must not be able to grant itself access. **Do
not** attempt to install it, ssh in to add it, or work around it. Print the exact line and
tell the user to add it on the receiver. Until they do, that host's sync silently no-ops.

## Safety & conventions

- **Never** read or commit credentials, `.env` files, or `*.key`. The `.gitignore` blocks
  `*.jsonl`, `*.credentials*`, and `.claude.json`; keep it that way.
- This repo is public-safe: don't introduce real hostnames, personal paths, IPs, or emails.
  Use RFC-safe placeholders (`192.168.x`, `home.ddns.example`, `claude-rx`, `laptop`).
- Do not add a `Co-Authored-By: Claude` trailer to commits.
- The dotclaude repos deploy directly from `main` (commit there is fine).
- Shell scripts are `bash`, `set -uo pipefail`; match the surrounding style.
- If you change docs, verify with `pip install -r requirements-docs.txt && mkdocs build --strict`.
