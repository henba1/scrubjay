# Session hand-off — continue a chat on another machine

Start a conversation on the laptop, finish it on the workstation. `/sjresume` stages a session that
was archived from **another** machine into this one, so Claude Code's own `--resume` picks it up
with its full history — subagents, task list and file history included.

```sh
# on the machine you're leaving (only if the session is still open — SessionEnd does this for you)
/sjlog

# on the machine you're moving to, from the project directory
/sjresume                     # pick from the other machines' recent sessions
/sjresume 4677b53a            # …or name it
/sjresume the foolbox refactor  # …or describe it (semantic recall)

# then, as Claude Code always has:
/resume                       # and pick it out of the list
```

## From a terminal: `claude resume <sid>`

Outside a session, skip the slash command. With scrubjay's shell integration installed, this works
for a session recorded on **any** machine:

```sh
cd ~/code/widget-api          # the folder to continue it in, on this machine
claude resume da79fffa        # the 8-hex handle, or a full id
claude --resume da79fffa      # same thing; so is -r, and any other flags are kept
```

It finds the session, stages it here exactly as `/sjresume` would, and then runs the real
`claude --resume <full-id>`:

1. **Which session.** The prefix is expanded against this machine's own transcripts and the
   cross-machine catalogue (`logs/<host>.log`, already on every machine, so no network). If it
   matches more than one session it lists them — host, date, folder, topic — and stops.
2. **Already here?** Then it is simply resumed. A session that belongs to another folder on this
   machine is resumed *from that folder* (Claude Code only looks in the current folder's project
   dir), as long as the folder still exists.
3. **Otherwise it is handed off** with `bin/sj-resume.sh` into the folder you are standing in — the
   other host's paths rewritten to it, the source host and folder printed — with `--no-clobber`:
   a local transcript is never replaced by a different one, not even with a backup. If the folder
   it was recorded in exists here too and you're somewhere else, it says so: `cd` there and re-run
   if that's where you meant to continue.

If the session's folder has moved and the [moves ledger](slash-commands.md#the-session-map) knows
where, it continues there, wherever you are standing. A hand-off on the machine that recorded the
session also rewrites any other moved path it finds.

A session from a different agent (opencode, codex) can't be resumed by `claude`; you get the same
carry-over command `/sjresume` prints instead.

**What gets intercepted, and what doesn't.** The integration is a `claude` shell function (bash
and zsh) in `bin/sj-shell.sh`. It intercepts only `resume <id>` as the *first* word, or `--resume` /
`-r` / `--resume=` followed by something that looks like a session id (8–36 hex digits and dashes).
Everything else — `claude`, `claude -p "resume the build"`, `claude --resume` (the picker),
`claude --resume <search words>` — goes straight to the binary after one pattern match on the
arguments, so there is no startup cost. (The same file also defines `opencode` and `codex`, for
[keeping agents running](keep-alive.md) when the
terminal closes; that only runs when you launch one from a terminal outside tmux.)

**Installing it.** Once per machine:

```sh
bash ~/.scrubjay/scrubjay/bin/sj-shell-install.sh     # then open a new shell
```

It adds one marked block to `~/.bashrc` and/or `~/.zshrc` that sources the snippet *through*
`~/.claude/hooks` — the symlink scrubjay's config sync keeps aimed at the app — so later updates
arrive with every app pull and no further rc edit. `--status` checks it, `--uninstall` removes the
block and nothing else. `bin/onboard.sh` offers it on new machines (`SCRUBJAY_SHELL_HOOK=1|0` answers
unattended), and `/sjdoctor` notes when it's missing.

## Why this is barely any machinery

`claude --resume <sid>` reads exactly **one file**: `~/.claude/projects/<slug>/<sid>.jsonl`. There
is no session database to reconstruct. And the relay already archives that file *byte-for-byte* at
`<archive>/<host>/<slug>/<sid>.jsonl` — the transcript **is** the resumable artifact, which is why
[transports.md](transports.md) calls the `.jsonl` "the thing you'd resume or feed to a tool."

So a hand-off is only three moves: fetch the file, fix the absolute paths inside it, and drop it in
the right local project dir. `bin/sj-resume.sh` does exactly that, and then gets out of the way.

## What travels, and what doesn't

| | |
|---|---|
| ✅ The conversation | Every turn, verbatim. |
| ✅ Subagents + tool results | The `<sid>/` sidecar dir. |
| ✅ The task list | Restored to `~/.claude/tasks/<sid>/`. |
| ✅ File history | Restored to `~/.claude/file-history/<sid>/`, so **`/rewind` still works**. |
| ❌ **The working tree** | **The transcript travels; your code does not.** |

That last row is the real ceiling on this feature, and it is worth being blunt about. The
conversation remembers editing `src/a.py` on branch `feature-x`. Whether that file exists here, at
that commit, is git's job — not the relay's. `sj-resume.sh` **checks and warns** when the branch
differs or the tree is dirty; it will not sync code, and you should not want it to.

## Paths get rewritten

A transcript from an HPC login node is full of `/gpfs/home2/you/code/VERONA`. On your laptop the
repo is at `/home/you/code/VERONA`. Left alone, the resumed Claude re-reads its own history, tries
to open files that don't exist, and burns turns rediscovering the repo.

So the importer remaps the session's project root to this machine's — in the `cwd` of every record
*and* throughout the message bodies (tool inputs, tool results, prose). It's a literal substitution
on the raw text (paths inside JSON strings carry no escapes, so it's exact), and the result is
validated — same record count, every line still parses — before anything is installed. If validation
fails, the verbatim archive copy is installed instead and you're told.

Anything the importer can't infer goes in `~/.config/scrubjay/config`:

```sh
# old:new, one per line — e.g. a home that is /home/you here and /gpfs/home2/you there
SCRUBJAY_PATH_MAP="/gpfs/home2/you:/home/you"
```

!!! note "Symlinked homes are handled automatically"
    The project slug is a pure function of the *resolved* path, so a machine whose home is
    symlinked (`/home/you` → `/gpfs/home2/you`) records one path in `cwd` and a different one in the
    message bodies. The importer recovers the real root by finding the ancestor path whose slug
    matches the archived one — no config needed.

## The session keeps its id

Continue `4677b53a` on a second machine and the archive ends up holding
`hostA/<slug>/4677b53a….jsonl` **and** `hostB/<slug>/4677b53a….jsonl` — one logical conversation, a
per-host copy. Nothing is clobbered (each machine only ever writes into its own `<host>/` subtree),
`sid8` stays the single handle you search by, and a re-import always takes the **longest** copy,
since a hand-off only ever appends turns.

Two guards keep that honest:

- If the local copy is **longer** than the archive's, the import refuses — those are turns that
  happened here and were never published. Run `/sjlog`, or pass `--force`.
- Any file it does overwrite is backed up to `<sid>.jsonl.bak` first.

To *branch* rather than continue, use Claude Code's native flag: `claude --resume <sid>
--fork-session`.

The catalogue records the hand-off. The first row this machine writes for the session carries
`resumed_from=<host>:<sid>`, so `/sjview` draws it as one session that ran on two machines
(`laptop → henpi`). A carry-over into another agent starts a new session. Its first row names the
session it came from, and `/sjview` joins the two with a "carried over" link. That session is
recognised as the first one started in the same folder and agent within a day.

## Reading back from a write-only relay

The `rsync-wg` relay key is pinned to `rrsync -wo` — **write-only, on purpose**, so a stolen relay
key can never read the archive back. That property is not weakened here.

Instead, the hand-off reads over the key you already have for [querying the archive](archive-mcp.md):
the one pinned to `bin/sjmcp-serve.sh`, which is read-only and confined to the archive root. It now
answers two extra verbs over `$SSH_ORIGINAL_COMMAND`:

| Verb | Returns |
|---|---|
| `resolve <sid>` | `<relpath> <lines> <mtime>` for every archived copy of that session |
| `fetch <relpath>` | a tar stream of that archive entry (file or directory) |
| *(no command)* | the MCP server, exactly as before |

This is **not** a wider grant: that key can already hand out the same raw `.jsonl` through
`sj_get(format="raw")`. It's a cheaper, binary-safe channel for bytes it may already read — a whole
transcript over MCP would have to cross the client's context window to reach its disk. Everything
else is refused, and both verbs re-check the resolved path against the archive root, so a symlink
inside the archive can't be used as a way out.

If a machine on `rsync-wg` has never run `bin/onboard-mcp-client.sh`, it has no read channel at all
and `/sjresume` says so. That script is the fix.

On the `local` and `git` backends none of this applies — the archive is a directory (or a clone) on
the box already, so reading it back is just a copy.

## The script, directly

`/sjresume` is a thin wrapper — it resolves a description to a session id and calls the script. You
can run it yourself; it must be run **from the project directory on this machine**, since that is
what the other host's paths get rewritten *to*.

```sh
sj-resume.sh --list [n]        # what's resumable, from other machines (default 15)
sj-resume.sh <sid|sid8>        # stage it into the project dir you're standing in
```

| Flag | Why you'd reach for it |
|---|---|
| `--into <dir>` | The project lives somewhere else here. Stage against `<dir>` instead of `$PWD`. |
| `--no-clobber` | Never replace an existing local transcript that differs from the archive's — refuse instead, even where `--force`-less staging would back it up and replace it. `claude resume <sid>` always passes it. |
| `--force` | Import even when the local copy is **longer** than the archive's. The refusal exists to protect unpublished turns — prefer `/sjlog` on the other machine first. The overwritten file is still backed up to `<sid>.jsonl.bak`. |
| `--no-rewrite-paths` | Install the archive copy **verbatim**. For inspecting a transcript as it was recorded; a session staged this way still points at the other machine's paths. |
| `--json` | For a program driving the hand-off (an editor's session list): stdout is exactly one JSON object — `mode` (`native` or `context`), `sid`, `src_host`, `src_harness`, `tgt_harness`, `cwd`, `cmd`, plus `staged`/`installed` or `primer` — or `{"ok":false,"error":…}`; the narration goes to stderr. With `--list` it prints the **whole** catalogue as JSON lines, this host's sessions too (`"here": true`). |

An 8-hex prefix is enough, but only if it is unambiguous: if the prefix matches more than one
*distinct* session the script lists them and stops, rather than guess which conversation you meant.

## Under the hood

`hooks/transports/<backend>.sh` now defines a read side alongside `transport_ship`:

```sh
transport_resolve <sid>            # -> TSV: <relpath> <lines> <mtime>
transport_fetch   <relpath> <dst>  # file or directory
```

`local` and `git` implement both against the filesystem; `rsync-wg` implements them over the sjmcp
SSH channel above. `bin/sj-resume.sh` is the only caller.

The **catalogue** — "what could I even resume?" — needs no network: `logs/<host>.log` in the data
repo already records every session that ever ended on every machine (`ts | host | cwd | topic |
session=<sid>`) and rides git to this one. The archive stays authoritative for the *path*, via
`transport_resolve`.
