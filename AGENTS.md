# AGENTS.md — guidance for coding agents in this repo

This file is for AI coding agents (Claude Code, Cursor, etc.) working in **scrubjay**.
Humans should start at [`README.md`](README.md) and the docs site.

## What this repo is

scrubjay is the **app/logic** for syncing [Claude Code](https://claude.ai/code) across
machines: a git-based config sync plus a pluggable, peer-to-peer transcript relay to the
user's own NAS. It is one of three repos — this one holds **only machinery** and is
public-safe; the user's actual content lives in two *private* sibling repos that are **not**
in this checkout:

| Repo | Role |
|---|---|
| **scrubjay** (this) | scripts, hooks, docs — the logic |
| **scrubjay-data** | `hosts/`, `settings/`, `claude-md/`, `shared/`, `opencode/`, `templates/`, `memory/`, `logs/` |
| **scrubjay-chats** | full chat transcripts (`.jsonl`), relayed off each machine |

Read [`docs/concepts.md`](docs/concepts.md) for the design (the "author-vs-record picks
git-vs-rsync; sensitive-vs-not picks NAS-vs-GitHub" model). Full docs build with MkDocs
(`docs/`, `mkdocs.yml`).

## Repo map

- `bin/` — the shell logic. Entry point for setup is `bin/onboard.sh`; `bin/sj-bootstrap.sh`
  creates + seeds the user's private repos; `bin/lib.sh` holds shared helpers;
  `bin/sync-config.sh` applies data-repo config into every harness this machine uses, via
  `bin/claude-sync.sh` for Claude Code.
- `bin/adapters/<harness>.sh` — **the harness seam.** scrubjay is not Claude-only: an adapter says
  where a coding agent keeps its config, what a session's records are, and how a session is
  resumed. `claude.sh` is the reference implementation; `opencode.sh` and `codex.sh` relay those
  harnesses' sessions into the same archive (opencode's lifecycle bridge is the plugin
  `hooks/opencode/scrubjay.js` + `publish.sh`; codex reuses the hook scripts as-is). Each brings its own readable
  renderer (`bin/render-{transcript,opencode,codex}.sh`) emitting one shared Markdown shape — that
  is what makes `/sjrecall` search across harnesses. The contract is in `bin/adapters/README.md`,
  the remaining work in `bin/adapters/ROADMAP.md`.
  Everything between the two seams — the archive layout, the `logs/` catalogue, memory, the readable
  Markdown layer, sjmcp — is harness-agnostic. Which harnesses a machine syncs is
  `SCRUBJAY_HARNESSES`; which one a hook invocation belongs to is `SCRUBJAY_HARNESS`.
- `skeleton/data/` — the seed for a fresh `scrubjay-data`. `settings/settings.base.json` is
  load-bearing: `claude-sync.sh` requires it, and it registers the SessionStart/SessionEnd hooks.
- `hooks/` — `sync-session.sh` (SessionStart), `log-session.sh` (SessionEnd), and
  `transports/<backend>.sh` (`git` / `rsync-wg` / `local`) — **the transport seam.** A backend
  defines `transport_ship` (write) plus `transport_resolve` / `transport_fetch` (read — used only
  by session hand-off).
- `bin/sj-resume.sh` — cross-machine session hand-off: stage another host's archived transcript into
  this machine's `~/.claude/projects/` so `claude --resume` continues it. See `docs/handoff.md`.
- `mcp/sjmcp_server.py` — the read-only archive MCP server (`uv run --script`).
  `bin/sjmcp-serve.sh` is its receiver-side forced command, and also answers `resolve`/`fetch` over
  `$SSH_ORIGINAL_COMMAND` so write-only `rsync-wg` hosts have a read path for hand-off.
- `commands/` — the generic `/dc*` slash commands shipped with the app.
- `skeleton/host/` — template copied when registering a new machine.
- `docs/` — the documentation site (also the source for the published site + `llms.txt`).

## Assisted install — onboarding a new machine

A common reason a user opens you here is *"set up scrubjay on this machine."* Drive
`bin/onboard.sh` for them — it is interactive, but every prompt honors a preset env var, so
you can gather the choices in chat and run it unattended. (This mirrors the `/sjonboard`
command in `commands/sjonboard.md`, which only exists *after* install — on a fresh clone you
are the front-end.)

The user does **not** fork this repo — it's the app and runs from upstream. Their content lives in
private repos under their own account (`scrubjay-data`; `scrubjay-chats` on the `git` backend;
`scrubjay-memory` for memory). `bin/sj-bootstrap.sh` creates + seeds any that are missing, using the
`gh` CLI. It refuses to treat the upstream account as the user's, so `SCRUBJAY_OWNER` matters.

Steps:

1. **Gather choices in chat:** the GitHub account that will own their private repos
   (`SCRUBJAY_OWNER` — default `gh api user`); stable host name; relay backend (`rsync-wg` /
   `local` / `git` / `off` — present them as peer options, no default) and its settings — for
   `rsync-wg`/`git` the receiver `user` / `host` / `port` / rrsync-`path`; for `local` either the
   already-mounted NAS storage path (`LOCAL_CHATS`) **or** the share details so onboard mounts it
   for you (`SCRUBJAY_NAS_SERVER` / `_EXPORT` / `_PROTO=nfs|cifs` / `_MOUNTPOINT`, via
   `bin/sj-mount.sh` — see below); which coding harnesses to sync config into (`SCRUBJAY_HARNESSES` — onboard
   auto-detects installed ones via each adapter's PATH-based `sjh_present`, so you usually only
   set this to override, e.g. an opencode that isn't on PATH yet); and whether to enable
   cross-machine memory (on the `git` backend this puts real filesystem paths in a private GitHub
   repo — surface that trade-off, don't just enable it).
2. **Confirm, then run non-interactively** from the clone, e.g.:

   ```sh
   SCRUBJAY_OWNER=<gh-user> SCRUBJAY_HOST=<host> SCRUBJAY_BACKEND=<backend> \
   SCRUBJAY_HARNESSES="claude opencode" \
   RECV_USER=<user> RECV_HOST=<host-or-ip> RECV_PORT=<port> RECV_PATH=<rrsync-root> \
   bash ./bin/onboard.sh </dev/null
   ```

   (Omit the `RECV_*` for `local`/`off`. For `local`: `LOCAL_CHATS=<path>` if the NAS is already
   mounted, else preset `SCRUBJAY_NAS_SERVER=<nas> SCRUBJAY_NAS_EXPORT=<share> SCRUBJAY_ASSUME_YES=1`
   so onboard runs `sj-mount.sh` and installs the mount (systemd `.mount` unit, sudo) unattended —
   for `cifs` it prints how to place a mode-600 credentials file, which stays yours to create. Omit
   `SCRUBJAY_HARNESSES` to accept auto-detection.)
3. **Report what changed** and surface the manual step below.

If `gh` is absent, `sj-bootstrap.sh` prints the exact `gh repo create` commands and stops. Relay
those to the user and let *them* run them — creating repos on someone's account is theirs to do.

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
  Use RFC-safe placeholders (`192.168.x`, `home.ddns.example`, `scrubjay-rx`, `laptop`).
- Do not add a `Co-Authored-By: Claude` trailer to commits.
- The scrubjay repos deploy directly from `main` (commit there is fine).
- Shell scripts are `bash`, `set -uo pipefail`; match the surrounding style.
- If you change docs, verify with `pip install -r requirements-docs.txt && mkdocs build --strict`.
