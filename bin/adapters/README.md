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
| `sjh_session_slug <transcript> <cwd>` | the `<slug>` this session archives under |
| `sjh_session_topic <transcript>` | first real user prompt, one line of plain text |
| `sjh_session_cwd <transcript>` | the working dir recorded inside the transcript |
| `sjh_render <transcript>` | the readable Markdown rendering, on stdout |
| `sjh_extra_artifacts <transcript> <sid> <slug> <cwd>` | TSV of the session's *other* records to relay (below) |
| `sjh_find_live_transcript <cwd>` | the in-progress session's transcript, for a publish-now with no hook payload |
| `sjh_slug <path>` | the harness's own project-dir encoding of an absolute path |
| `sjh_project_dir <cwd>` | where a transcript for `<cwd>` must land locally to be resumable |
| `sjh_import_side <sid> <dir> <project_dir>` | put fetched sidecar records back where the harness expects them |
| `sjh_resume_cmd <sid>` | the command a user runs to continue the session |

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
