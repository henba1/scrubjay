# dotclaude

The **app/logic** for syncing [Claude Code](https://claude.ai/code) across machines. Your
personal content is kept in *separate* repos so this one can be shared/public without
leaking anything:

| Repo | Role | Visibility |
|---|---|---|
| **dotclaude** (this) | scripts, hooks, docs — the logic | public-able |
| **dotclaude-data** | `hosts/`, `settings/`, `claude-md/`, `templates/`, `memory/`, `logs/` | private |
| **claude-chats** | full chat transcripts (`.jsonl`), relayed off each machine | private |

![dotclaude — system overview](docs/overview.svg)

<sub>Diagram source: [`docs/overview.dot`](docs/overview.dot) — `dot -Tsvg docs/overview.dot -o docs/overview.svg`.</sub>

> **Flow:** `dotclaude` (logic) + `dotclaude-data` (your config) → applied into each
> machine's `~/.claude` by `claude-sync.sh`. On `SessionEnd` a hook appends a one-line
> entry to `dotclaude-data/logs/<host>.log` *and* ships the full transcript to
> `claude-chats`; a Raspberry Pi mirrors that into the NAS. Top-level is keyed by machine
> so envs stay distinct and Claude can re-tailor one host's rules for another.

## HOW-TO (start here)

### 0. What is dotclaude?

[Claude Code](https://claude.ai/code) reads its configuration from a `~/.claude/`
directory on whatever machine you run it on: which rules it must follow, which custom
commands and sub-agents exist, what it's allowed to do, and so on. If you work on several
machines (a laptop, a desktop, an HPC cluster) you'd normally set all of that up by hand,
separately, on each one — and they'd drift apart over time.

dotclaude keeps that configuration in **git** instead, and makes it apply itself. This
repo (`dotclaude`) holds only the *machinery* — the shell scripts and hooks. Your actual
content lives in a second, private repo (`dotclaude-data`) that we call **the database**.
A small sync step turns the database into a working `~/.claude/` on each machine, and a
pair of hooks keep it current automatically. The result: you configure Claude once, and
every machine stays in step.

### 1. What's in the database (`dotclaude-data`) and how Claude uses it

The database is just plain Markdown and JSON files, organised into a handful of
directories. Each one feeds Claude in a specific way:

- **`claude-md/`** — the configuration shared by *all* your machines. `CLAUDE.md` is the
  always-on instruction file Claude reads at the top of every session (e.g. *"never add a
  `Co-Authored-By` trailer to commits"*). `commands/` holds custom slash-commands you can
  invoke by name — `commands/explain-diff.md` becomes `/explain-diff`, which might tell
  Claude to summarise your staged git changes. `agents/` holds sub-agents Claude can
  delegate to — `agents/test-runner.md` defines a focused helper that runs your test suite
  and reports back. These three are symlinked straight into `~/.claude/`, so editing a file
  here changes Claude's behaviour everywhere on the next pull.

- **`hosts/<machine>/`** — the part that is *different* per machine. `env.md` describes that
  box in prose (its OS, where Python lives, cluster quirks) so Claude knows the lay of the
  land; `claude/settings.json` holds machine-specific overrides (for example, this HPC node
  auto-accepts edits); `chats.index.json` is an auto-generated catalogue of which chats live
  on that machine. Because hosts sit at the top level, one machine's setup never leaks into
  another's — and you can ask Claude to *"read `hosts/laptop/` and adapt it for this HPC
  box"*.

- **`settings/`** — `settings.base.json` is the baseline `~/.claude/settings.json` that
  applies everywhere: the permission allow/deny lists (which shell commands Claude may run
  without asking), the default model, and which hooks fire. The sync step merges this
  baseline with the per-host overrides from `hosts/<machine>/` into the final settings file.

- **`memory/`** — durable facts Claude has learned about you and should remember across
  sessions, one fact per file (e.g. `feedback_no_coauthored_by.md`). These are pulled in on
  demand rather than symlinked.

- **`templates/`** — reusable starting points for *project-level* config, kept out of the
  always-on path. `templates/verona-foolbox/CLAUDE.local.md` is a ready-made rules file you
  can drop into a specific project so Claude picks up that project's conventions.

- **`logs/`** — a human-readable history of every session, one file per machine
  (`<host>.log`). Each line records the time, machine, working directory, and your first
  prompt, so you can later `grep` for *"that chat about foolbox"* across all machines.

- **`runbooks/`** — operational notes for *you* (not Claude), like the plan for moving chat
  transcripts off GitHub onto a private WireGuard link.

### 2. How the system works, and what you set up once

The moving parts fit together like this:

1. **Two repos, one machine-local pointer.** You clone `dotclaude` (this machinery) and
   `dotclaude-data` (your content) onto each machine. A tiny file at
   `~/.config/dotclaude/config` tells the scripts where those clones live, and
   `~/.config/dotclaude/host` pins a stable name for the machine (handy on clusters whose
   hostnames change between logins).

2. **Sync turns the database into `~/.claude/`.** Running `bin/claude-sync.sh` symlinks the
   shared `claude-md/` scopes into `~/.claude/` and merges `settings/` + the host overrides
   into `~/.claude/settings.json`. It's safe to re-run; it only changes what actually
   differs.

3. **Two hooks keep it hands-off.** When a session *starts*, a hook pulls the latest
   `dotclaude-data` and re-runs sync, so config you edited on another machine is already in
   effect. When a session *ends*, a hook appends the log line, refreshes that machine's chat
   index, and commits both back. You don't run these — they run themselves.

**What you actually do once per machine:** clone the two repos, write the little config
pointer, run `claude-register-host.sh` to scaffold a `hosts/<machine>/` entry, then
`claude-sync.sh` to apply it. After that, you only ever *edit files in `dotclaude-data` and
push* — every machine converges on its own. The concrete commands are in
[Onboard a new machine](#onboard-a-new-machine) below.

---

## Layout (this repo — app only)

```
bin/
  lib.sh                 # shared helpers: host + data/chats pointers
  claude-sync.sh         # apply data-repo config into ~/.claude (symlinks + merged settings)
  claude-index-chats.sh  # write dotclaude-data/hosts/<host>/chats.index.json
  claude-register-host.sh# scaffold a new host into the data repo
  ship-transcript.sh     # relay a transcript via the selected backend
  pull-and-mirror.sh     # (Pi) pull claude-chats -> NAS
hooks/
  sync-session.sh        # SessionStart hook: pull data repo + claude-sync (auto-fresh config)
  log-session.sh         # SessionEnd hook: log line + refresh index + ship transcript
  transports/git.sh      # transcript backend: git (current)
  transports/rsync-wg.sh # transcript backend: WireGuard rsync (upcoming, stub)
skeleton/host/           # template copied when registering a new machine
docs/                    # overview diagram, raspberry-pi.md, transcript-transport.md
```

## Pointers (machine-local)

The app finds your data/transcript repos via `~/.config/dotclaude/config` (env overrides):

```sh
: "${DOTCLAUDE_DATA:=$HOME/code/dotclaude-data}"
: "${DOTCLAUDE_CHATS:=$HOME/code/claude-chats}"
: "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
```

Host identity is pinned separately in `~/.config/dotclaude/host` (because `hostname -s`
is transient on HPC login nodes).

## Onboard a new machine

```sh
git clone git@github.com:henba1/dotclaude.git      ~/code/dotclaude
git clone git@github.com:henba1/dotclaude-data.git ~/code/dotclaude-data
git clone git@github.com:henba1/claude-chats.git   ~/code/claude-chats   # if syncing transcripts

mkdir -p ~/.config/dotclaude && cat > ~/.config/dotclaude/config <<'EOF'
: "${DOTCLAUDE_DATA:=$HOME/code/dotclaude-data}"
: "${DOTCLAUDE_CHATS:=$HOME/code/claude-chats}"
: "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
EOF

~/code/dotclaude/bin/claude-register-host.sh --host <name>   # scaffold + pin + index
# review ~/code/dotclaude-data/hosts/<name>/
~/code/dotclaude/bin/claude-sync.sh                          # apply into ~/.claude
git -C ~/code/dotclaude-data add -A && git -C ~/code/dotclaude-data commit -m "host <name>" && git -C ~/code/dotclaude-data push
```

Prereqs: `bash`, `jq`, `git`, an SSH key on GitHub. No root.

## Day-to-day — nothing to run by hand

Both housekeeping scripts run automatically via hooks, so you never update anything manually:

| When | Hook | Does |
|---|---|---|
| session **start** | `sync-session.sh` | `git pull --ff-only` the data repo, then `claude-sync.sh` — config edited on another machine arrives and applies itself. |
| session **end** | `log-session.sh` | append the log line **and** refresh `chats.index.json`, then commit + push. |

Symlinked scopes (`CLAUDE.md`, `commands/`, `agents/`, `hooks/`) go live on the pull
alone — `claude-sync.sh` only has real work when `settings.json` changed. You can still run
either by hand (both idempotent); the hooks just mean you don't have to:

```sh
bin/claude-sync.sh         # re-apply config (auto-runs at SessionStart)
bin/claude-index-chats.sh  # refresh this host's chats.index.json (auto-runs at SessionEnd)
```

Escape hatches (env, in `~/.config/dotclaude/config` or inline): `DOTCLAUDE_NOSYNC=1`
(skip the start-of-session pull+sync), `DOTCLAUDE_SYNC_NOPULL=1` (sync without pulling).

## Find a past chat

Every session is logged by the `SessionEnd` hook to `dotclaude-data/logs/<host>.log`
(one line: `time | host | cwd | "first prompt" | session=id`) and pushed, so all
machines' histories are searchable from any clone of the data repo:

```sh
git -C ~/code/dotclaude-data pull
grep -i foolbox ~/code/dotclaude-data/logs/*.log
```

The full transcript (the `.jsonl`) lives in `claude-chats` / on the NAS under
`<host>/<slug>/<session>.jsonl`.

## Transcripts: relay + NAS

`SessionEnd` ships each transcript via a **pluggable backend** (`ship-transcript.sh`).
Current backend `git` pushes to `claude-chats`; a Pi mirrors it to the NAS
([`docs/raspberry-pi.md`](docs/raspberry-pi.md)). The transport is designed to switch to
**peer-to-peer rsync over WireGuard** (no third-party server) —
[`docs/transcript-transport.md`](docs/transcript-transport.md).

Upload the existing back catalogue once (sessions that pre-date the hook):

```sh
bin/backfill-transcripts.sh    # ships every existing transcript; idempotent
```

## Cross-machine tailoring with Claude

Everything is plain Markdown/JSON, so from any project you can ask Claude: *"read
`dotclaude-data/hosts/<other>/` and adapt its rules for this box"* — it reads one host's
config and writes another's.
