# Concepts

## The core idea: two kinds of sync

Everything dotclaude moves is one of two things — and which one it is decides the
*mechanism*. Get this distinction and the rest of the system follows:

| Semantic | Meaning | Mechanism | What it fits |
|---|---|---|---|
| **Shared / bidirectional** ("cross-machine") | Same content on every machine; edits *merge* | **git** (pull + push) | things you *author*: `CLAUDE.md`, `commands`, `agents`, `settings`, `plugins`, **memory** |
| **Archive / one-way** | machine → NAS; never edited in two places, no read-back | **rsync** (the P2P "cart") | *records*: transcripts, subagents, plans, `readable/`, `history.jsonl`, `tasks` |

The second axis is **privacy**, and it's orthogonal: anything sensitive goes **straight
to your own NAS, never a third party**. So the *records* ride peer-to-peer rsync to the
NAS, and the one piece of *authored* content that's sensitive — **memory** (it carries
real file paths) — still uses git for the merge, but a git repo **self-hosted on the NAS
over WireGuard** rather than GitHub. Only the non-sensitive authored config rides GitHub
(`dotclaude-data`). That's the whole design in one sentence: **author-vs-record picks
git-vs-rsync; sensitive-vs-not picks NAS-vs-GitHub.**

### NAS or GitHub — your choice of shared store

The *record* half above is where a NAS shines, but a NAS isn't required. The transcript
transport is **pluggable**, and the two backends are genuinely parallel — you pick one when
you onboard:

- **Your own NAS** (`rsync-wg` / `local`) — records ride peer-to-peer to it over
  WireGuard/SSH; nothing ever touches a third party. The tradeoff is standing up a NAS + WireGuard.
- **GitHub** (`git`) — each session is pushed to a private `claude-chats` repo. Zero
  infrastructure to run; the tradeoff is that your transcripts live in a (private)
  third-party repo rather than only on your own hardware.

Same records, two destinations — choose by whether you'd rather manage your own storage or
none. (Config always rides GitHub either way. Cross-machine *memory* sync is set up
separately and is NAS-oriented; a GitHub-only setup typically keeps memory machine-local
until you point it at a git remote of your own — see
[Transcripts: relay + NAS](transports.md).)

## What is dotclaude?

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

## What's in the database (`dotclaude-data`) and how Claude uses it

The database is just plain Markdown and JSON files, organised into a handful of
directories. Each one feeds Claude in a specific way:

- **`claude-md/`** — the configuration shared by *all* your machines. `CLAUDE.md` is the
  always-on instruction file Claude reads at the top of every session (e.g. *"never add a
  `Co-Authored-By` trailer to commits"*). `commands/` holds custom slash-commands you can
  invoke by name — `commands/explain-diff.md` becomes `/explain-diff`, which might tell
  Claude to summarise your staged git changes. (The generic `/dc*` commands aren't here — they
  ship with the app; `claude-sync.sh` merges both into `~/.claude/commands/`.) `agents/` holds
  sub-agents Claude can delegate to — `agents/test-runner.md` defines a focused helper that runs
  your test suite and reports back. `CLAUDE.md` and `agents/` are symlinked straight into
  `~/.claude/`, so editing a file here changes Claude's behaviour everywhere on the next pull.

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

- **`memory/`** — durable facts Claude has learned and should remember across sessions, one
  fact per file. Claude Code's built-in auto-memory lives per-project at
  `~/.claude/projects/<project>/memory/`; `claude-sync.sh` symlinks each of those into this
  repo under `memory/<host>/<project>/`, so auto-saved memories are synced and sorted by the
  machine they were created on, then by project (mirroring Claude's native layout).

- **`templates/`** — reusable starting points for *project-level* config, kept out of the
  always-on path. A file like `templates/<project>/CLAUDE.local.md` is a ready-made rules
  file you can drop into a specific project so Claude picks up that project's conventions.

- **`logs/`** — a human-readable history of every session, one file per machine
  (`<host>.log`). Each line records the time, machine, working directory, and your first
  prompt, so you can later `grep` for *"that chat about the auth refactor"* across all machines.

- **`runbooks/`** — operational notes for *you* (not Claude), like the plan for moving chat
  transcripts off GitHub onto a private WireGuard link.

## How the system works, and what you set up once

The moving parts fit together like this:

1. **Two repos, one machine-local pointer.** You clone `dotclaude` (this machinery) and
   `dotclaude-data` (your content) onto each machine. A tiny file at
   `~/.config/dotclaude/config` tells the scripts where those clones live, and
   `~/.config/dotclaude/host` pins a stable name for the machine (handy on clusters whose
   hostnames change between logins).

2. **Sync turns the database into `~/.claude/`.** Running `bin/claude-sync.sh` symlinks the
   shared `claude-md/` scopes into `~/.claude/`, points each project's auto-memory dir at the
   synced `memory/<host>/<project>/`, and merges `settings/` + the host overrides into
   `~/.claude/settings.json`. It's safe to re-run; it only changes what actually differs.

3. **Two hooks keep it hands-off.** When a session *starts*, a hook pulls the latest
   `dotclaude-data` and re-runs sync, so config you edited on another machine is already in
   effect. When a session *ends*, a hook appends the log line, refreshes that machine's chat
   index, and commits both back. You don't run these — they run themselves.

**What you actually do once per machine:** clone the two repos, write the little config
pointer, run `claude-register-host.sh` to scaffold a `hosts/<machine>/` entry, then
`claude-sync.sh` to apply it. After that, you only ever *edit files in `dotclaude-data` and
push* — every machine converges on its own. The concrete commands are in
[Onboarding](onboarding.md).

## Cross-machine tailoring with Claude

Everything is plain Markdown/JSON, so from any project you can ask Claude: *"read
`dotclaude-data/hosts/<other>/` and adapt its rules for this box"* — it reads one host's
config and writes another's.
