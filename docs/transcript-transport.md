# Transcript transport (pluggable)

The `SessionEnd` hook relays a session's artifacts off each machine. The *how* is abstracted
so the backend can change without touching the hook. Three things are shipped, all via the
same backend (so sensitive content never takes a separate third-party path):

| Artifact | Source | Lands at |
|---|---|---|
| transcript | `~/.claude/projects/<slug>/<session>.jsonl` | `<host>/<slug>/<session>.jsonl` |
| subagents (subagent transcripts, tool-results) | `~/.claude/projects/<slug>/<session>/` | `<host>/<slug>/<session>/` |
| plans (sensitive; not session-keyed) | `~/.claude/plans/` | `<host>/plans/<date>_<topic>.md` |
| `CLAUDE.local.md` (personal project rules; host-specific) | `<project working tree>/CLAUDE.local.md` | `<host>/<slug>/CLAUDE.local.md` |

The layout is uniform: **`<host>/` + the same path Claude uses locally.** (Memory is the one
exception — it drops the host prefix because it's *shared* across machines, not archived per-host;
see `memory-sync.md`.) `CLAUDE.local.md` is host-specific, so it's a one-way per-host archive, not
merged like memory.

`transport_ship <src> <relpath>` accepts a file *or* a directory. (Memory is **not** shipped
here — it rides the `dotclaude-data` git sync.)

## How it's wired

```
SessionEnd hook (hooks/log-session.sh)
   └─ bin/ship-transcript.sh <transcript> <slug> <session> <host>
         └─ hooks/transports/<backend>.sh   ::  transport_ship <src> <host/slug/session.jsonl>
```

Backend is chosen by `DOTCLAUDE_TRANSCRIPT_BACKEND` in `~/.config/dotclaude/config`.
A backend is one file defining `transport_ship <src> <relpath>`.

## Current backend: `git`  (stopgap)

Copies the transcript into the `claude-chats` private repo (`DOTCLAUDE_CHATS`) and pushes
it. A mirror host pulls and mirrors to the NAS (`mirror-host.md`).

⚠️ Tradeoff: transcripts transit GitHub's servers. The repo is private and treated as a
*relay* (NAS is canonical), but this is why it's a stopgap.

## Backend: `rsync-wg`  (peer-to-peer, no third party)

Each machine holds a per-machine SSH key and rsyncs **over a WireGuard/SSH tunnel** directly
to the NAS receiver. No data on any third-party server.

Set in `~/.config/dotclaude/config`:

```sh
DOTCLAUDE_TRANSCRIPT_BACKEND="rsync-wg"
DOTCLAUDE_WG_TARGET="claude-rx@claude-receiver"            # ssh destination ONLY — no remote path
DOTCLAUDE_WG_SSHKEY="$HOME/.ssh/claude_transcripts_ed25519"
```

⚠️ **No remote path in `DOTCLAUDE_WG_TARGET`.** The receiver authorizes the key with a forced
`command="rrsync -wo <root>"`, which pins the destination root; everything the client sends is
taken **relative** to it. Including `:/srv/claude-chats` would make `rrsync` re-root it *under*
itself (`/srv/claude-chats/srv/claude-chats/…`). Per-machine reachability — `HostName`, the
(often non-standard) SSH **`Port`**, `User` — lives in a `~/.ssh/config` `claude-receiver`
alias, so this config line is identical on every machine. `bin/onboard.sh` writes both.

Receiver requirements (see the private `runbooks/wireguard-transcripts.md`):
- a restricted `command="rrsync -wo <root>",restrict` line per machine key (write-only, no shell);
- the `rrsync` user must be able to **traverse** to the NAS root (e.g. `setfacl -m u:claude-rx:x`
  on a `0750` parent like `/media/<user>`);
- `rsync ≥ 3.2.3` on both ends (for `--mkpath`).

## Backend: `local`  (the box that *is* the NAS)

The receiver itself (the machine with the NAS mounted) shouldn't rsync to itself over WG.
The `local` backend just copies the transcript straight into the NAS chats root:

```sh
DOTCLAUDE_TRANSCRIPT_BACKEND="local"
DOTCLAUDE_LOCAL_CHATS="/mnt/nas1/dotclaude-storage"   # the NAS storage root
```

Layout matches every other backend (`<host>/<slug>/<session>.jsonl`), so a `local` sender and
the WG receivers all write into one tree. Lives in `hooks/transports/local.sh`.

Adding any other transport (e.g. S3, syncthing) is just another
`hooks/transports/<name>.sh` defining `transport_ship`.
