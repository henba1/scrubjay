# Harness adapters

scrubjay has two pluggable seams. `hooks/transports/<backend>.sh` answers *"where do a session's
records go?"* (git / NAS / rsync). The adapters here answer the other half: *"which coding agent
produced them, and where does that agent keep its config, its transcripts, and its resumable
sessions?"*

Everything between the two seams — the archive layout (`<host>/{readable,plans,<slug>/<sid>.<ext>}`),
the data repo, the `logs/` catalogue, the memory repo, the readable Markdown layer, the sjmcp read
server — is harness-agnostic and shared.

An adapter is a bash file sourced into the caller's shell:

```sh
. "$APP/bin/lib.sh"
sj_load_adapter "$(sj_harness)"     # honours $SCRUBJAY_HARNESS, default: claude
```

Only ONE adapter is sourced per shell (the functions share a namespace), so a caller that walks
several harnesses — `bin/sync-config.sh` — must do it in a subshell each.

Which harnesses a machine syncs is `SCRUBJAY_HARNESSES` in `~/.config/scrubjay/config` (default
`claude`). Which harness a *given* hook invocation belongs to is `SCRUBJAY_HARNESS` (default
`claude`) — set by whatever fired the hook.

## The contract

Every `sjh_*` below is required. Bare `printf`/`return`, no `set -e` assumptions: adapters are
sourced into best-effort hook code that must never kill a session.

| Function | Returns |
|---|---|
| `sjh_present` | 0 if this harness is installed on this machine |
| `sjh_config_dir` | its config root (`~/.claude`, `~/.config/opencode`, `~/.codex`) |
| `sjh_apply_config [args]` | materialize the synced config into that root; idempotent |
| `sjh_transcript_ext` | extension an archived transcript carries (`jsonl`, `json`) |
| `sjh_session_handle <sid>` | the 8-char handle the session is known by (readable name, `/sjrecall`, `/sjresume`) |
| `sjh_session_slug <transcript> <cwd>` | the `<slug>` this session archives under |
| `sjh_session_topic <transcript>` | first real user prompt, one line of plain text |
| `sjh_session_cwd <transcript>` | the working dir recorded inside the transcript |
| `sjh_render <transcript>` | the readable Markdown rendering, on stdout |
| `sjh_extra_artifacts <transcript> <sid> <slug> <cwd>` | TSV of the session's *other* records to relay (below) |
| `sjh_find_live_transcript <cwd>` | the in-progress session's transcript, for a publish-now with no hook payload (empty if the harness has none on disk) |
| `sjh_slug <path>` | the harness's own project-dir encoding of an absolute path |
| `sjh_project_dir <cwd>` | where a fetched session must land locally to be resumable |
| `sjh_import_side <sid> <dir> <project_dir>` | put fetched sidecar records back where the harness expects them |
| `sjh_resume_cmd <sid> <staged-file>` | the command a user runs to continue the session (a harness that imports rather than reads in place needs the path) |

The readable Markdown rendering is the one artifact every harness produces in the same shape — a
`# title`, a `_N turns_` line, and `## User` / `## Assistant` blocks. That is what lets `/sjrecall`
and `/sjbrowse` search across harnesses, and what `mcp/sjmcp_server.py` parses. Keep to it.

### `sjh_extra_artifacts`

One record per line, tab-separated: `<src>` `<relpath-under-the-host-subtree>` `<mode>`.

`<src>` may be a file or a directory; a missing one is skipped by the caller. `<mode>` is empty, or
`mirror` to make the relay copy authoritative (dest entries not in src are dropped — that is what
keeps a renamed plan from lingering under its old name). The caller prefixes `<host>/`.

This is where a harness declares the records that are *not* the transcript — plans, prompt history,
task lists, per-session file history, subagent transcripts. It may normalize files in place first
(the Claude adapter renames plans to `<date>_<topic>.md` here).

## Adding a harness

1. Write `bin/adapters/<name>.sh` implementing the table above.
2. Teach it to fire scrubjay's lifecycle: SessionStart → `hooks/sync-session.sh`, session end →
   `hooks/log-session.sh` (or, for a harness whose transcript is not a file on disk, export it and
   call `bin/ship-transcript.sh <file> <slug> <sid> <host> <cwd>` directly with
   `SCRUBJAY_HARNESS=<name>` in the environment).
3. Add `<name>` to `SCRUBJAY_HARNESSES`.

## Harnesses

### claude — Claude Code

The reference adapter, and the only one with full config sync (CLAUDE.md, agents, commands,
settings merge, per-project memory, MCP registration — `bin/claude-sync.sh`) and in-place session
hand-off (`bin/sj-resume.sh`).

### opencode

Add it on a machine that has `opencode`:

```sh
echo ': "${SCRUBJAY_HARNESSES:=claude opencode}"' >> ~/.config/scrubjay/config
bin/sync-config.sh
```

`sync-config.sh` then writes three things into `~/.config/opencode/` — additively, never clobbering
config it doesn't own:

| What | Where | Effect |
|---|---|---|
| the lifecycle bridge | `opencode.json` → `plugin[]` | sessions are logged + relayed to the archive |
| the sjmcp archive server | `opencode.json` → `mcp.sjmcp` | `/sjrecall` & co. can read the archive |
| the `/sj*` commands | `commands/*.md` (generated) | the slash commands exist in opencode |

So an opencode session is archived (transcript + readable rendering), lands in the `logs/`
catalogue, and is searchable from *either* harness — a session started in Claude Code on one
machine is recallable from opencode on another, and vice versa.

Still missing: syncing config *into* opencode (`AGENTS.md`, `agents/`, a base+host settings merge),
and an automatic import on hand-off — `bin/sj-resume.sh` stages the export into an inbox and prints
the `opencode import … && opencode --session …` for you to run.

Three things worth knowing about how it works:

* **It publishes on `session.idle`, not at session end** — opencode has no "session ended" event
  (a killed TUI sends nothing). So the bridge publishes after every turn, skipping an export that
  is byte-identical to the last one shipped. A crashed opencode session is therefore already
  archived up to its last turn, which Claude's SessionEnd cannot promise. (`/sjlog` is consequently
  a "flush now", not a "or these turns are lost".)
* **The archived transcript is `opencode export` output**, which `opencode import` reads back — so
  the archive holds a natively re-importable session, not a scrubjay-specific dump.
* **The commands are generated, not written** — `commands/*.md` is the single source, translated on
  each sync (opencode has no `allowed-tools`, namespaces MCP tools `sjmcp_sj_recall` rather than
  `mcp__sjmcp__sj_recall`, and cannot find the app by following `~/.claude/hooks`). Edit
  `commands/`, never the copies in the opencode config dir.

### codex

Session relay + archive. Add it on a machine that has `codex`:

```sh
echo ': "${SCRUBJAY_HARNESSES:=claude codex}"' >> ~/.config/scrubjay/config
bin/sync-config.sh          # registers the hooks in ~/.codex/hooks.json
```

Codex needs **no bridge at all** — it is the only other harness whose hooks hand a command the same
payload Claude's do (`session_id` / `cwd` / `transcript_path`, in
`codex-rs/hooks/schema/generated/*.command.input.schema.json`), so `hooks/sync-session.sh` and
`hooks/log-session.sh` run against it unchanged. All the adapter supplies is the config dir, the
rollout's record schema, and a renderer.

Worth knowing:

* **It publishes on `Stop`, which is per-turn** — codex has no SessionEnd either. Costs nothing: the
  transports are idempotent, and the `git` backend only commits when content actually changed.
* **`transcript_path` is nullable.** When it comes through null the adapter finds the rollout itself,
  by session id (exact) or by the session's cwd (fallback).
* **The rollout's parent directory is a DATE** (`sessions/2026/07/14/`), not a project — so the
  archive slug comes from the session's cwd, like opencode's.

Not yet: sjmcp + the `/sj*` commands (codex config is TOML — see the roadmap), and hand-off *into*
codex (`codex resume` resolves a session through codex's own index, so staging a file is not enough).
