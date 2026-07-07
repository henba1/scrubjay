# Cross-machine memory over its own git repo

Auto-memory (`~/.claude/projects/<project>/memory/`) wants git's **bidirectional merge + history** so
the same project recalls memory written on any machine — so it rides its **own dedicated git repo**,
separate from everything else. Where that repo lives mirrors your transcript backend, and the choice is
a **custody trade-off** because memory holds **real filesystem paths**:

- **Self-hosted on the NAS** (`local` / `rsync-wg` backends) — a bare repo on your own hardware, reached
  over the existing WireGuard tunnel. **No third party ever sees it.** This is the default and the
  reason the setup exists: sensitive paths stay on gear you own. The cost is standing infrastructure —
  a NAS box, WireGuard, DDNS.
- **A private GitHub repo** (`git` backend) — a separate private `claude-memory` repo, pushed with your
  normal GitHub SSH credentials (no dedicated key, no receiver step — simpler than the NAS path). The
  trade-off: your memory's real filesystem paths now sit in a **third party's** private repo (encrypted
  at rest, private, but off your hardware). Choose this if that's acceptable and you'd rather skip the
  NAS/WireGuard/DDNS wiring.

Either way it's the *same* mechanism below — only `DOTCLAUDE_MEMORY_REMOTE` differs.

```
~/.claude/projects/<project>/memory/   ──symlink──►   $DOTCLAUDE_MEMORY/<project>/   (local clone)
                                                              │  git pull --rebase  (SessionStart)
                                                              │  git push           (SessionEnd)
                                                              ▼
                                          $DOTCLAUDE_MEMORY_REMOTE  =  bare repo on the NAS
                                          (local path on the NAS box · ssh://…over-WG on clients)
```

- `bin/memory-sync.sh pull|push` — clones on first use, then pulls/pushes. Best-effort, never blocks.
- `bin/claude-sync.sh` — symlinks each project's memory dir into the clone (**shared**, not per-host),
  and on first run migrates any legacy `dotclaude-data/memory/<host>/` content into it.
- Hooks: `sync-session.sh` pulls before linking; `log-session.sh` pushes at session end.

## Config keys (`~/.config/dotclaude/config`)

```sh
: "${DOTCLAUDE_MEMORY:=$HOME/.dotclaude/claude-memory}"          # local working clone
: "${DOTCLAUDE_MEMORY_REMOTE:=...}"                              # the bare repo (see below)
```

If `DOTCLAUDE_MEMORY_REMOTE` is unset, memory sync is **off** — the dir is just machine-local.

## Setup — automated

`bin/onboard-memory.sh` does all of the below, idempotently, on any machine — it's also run by
`bin/onboard.sh` and exposed as the **`/dcmemory`** slash command. Run it once; re-running on an
already-configured machine is a safe no-op:

```sh
bin/onboard-memory.sh        # or: /dcmemory   (from inside a session)
```

- **NAS box** (`local` backend): derives the bare-repo path from the NAS root, `git init --bare`s it
  if absent, sets the config keys, then clones + migrates legacy memory in + links the memory dirs.
- **WG client** (`rsync-wg` backend): generates a dedicated `claude_memory_ed25519` key + a
  `claude-memory` ssh alias (cribbing host/port from the `claude-receiver` alias), sets the config
  keys, and **prints the one `authorized_keys` line** to add on the receiver (the server-side step
  stays manual — see below). Override anything via `MEM_BARE`, `MEM_GIT_USER`, `MEM_RECV_HOST`, etc.
- **GitHub-only** (`git` backend): points `DOTCLAUDE_MEMORY_REMOTE` at a **separate private GitHub repo**,
  defaulting to a `claude-memory` sibling of your other repos (derived from the `claude-chats`/app clone's
  owner; override with `MEM_GIT_REMOTE`). No key or receiver step — it uses your normal GitHub SSH
  credentials. **You must create that empty private repo on GitHub first** (GitHub won't auto-create it);
  the first push populates it. `onboard-memory.sh` prints the privacy trade-off before wiring it.

## Setup — what it does by hand (reference)

NAS box (the bare repo lives **inside** the NAS storage folder, next to the transcript trees):
```sh
git init --bare /mnt/nas1/dotclaude-storage/memory.git          # the bare repo
# DOTCLAUDE_MEMORY_REMOTE=/mnt/nas1/dotclaude-storage/memory.git     (a LOCAL path; no SSH hop here)
bin/memory-sync.sh pull && bin/claude-sync.sh && bin/memory-sync.sh push
```

`onboard-memory.sh` also installs a `post-receive` hook on the bare repo that checks the latest
`main` out into a sibling **`dotclaude-storage/memory/`** — a human-browsable copy on the NAS,
refreshed on every push (from this box or any client). The bare repo stays the sync hub; `memory/`
is just a convenience view (don't edit it — it's overwritten on the next push).

WG client — git needs **full git-over-SSH**, and the transcript relay key can't be reused (its
forced `rrsync -wo` command blocks git). `onboard-memory.sh` makes the key + alias; you add its
public key on the receiver, restricted to git:

```sh
# on the receiver, in the git user's ~/.ssh/authorized_keys (printed for you by onboard-memory.sh):
command="git-shell -c \"$SSH_ORIGINAL_COMMAND\"",restrict ssh-ed25519 AAAA... <host> memory-git
# then on the client:  DOTCLAUDE_MEMORY_REMOTE=claude-memory:/srv/claude-chats/memory.git
#   (/srv/claude-chats is the receiver's symlink to the dotclaude-storage folder)
bin/memory-sync.sh pull && bin/claude-sync.sh
```

From then on the client pulls others' memory at session start and publishes its own at session end.
Concurrent edits merge via `git pull --rebase --autostash`; a genuine conflict is left for you to
resolve in the clone (memory files are small Markdown, so this is rare).

## Receiver one-time admin (per box, NOT per client)

The memory ride reuses the transcript relay's *connection* (same host, port, account, jump host) —
the only thing that differs is the **key** (the receiver pins each key to one forced command:
`rrsync -wo` for transcripts, `git-shell` for memory). So `onboard-memory.sh` on a WG client just
generates a second key and an alias that inherits the relay's connection. Three things on the
**receiver** are inherently manual (they need root and/or a *different* user than the one running
onboard) and aren't auto-applied — do them once when you first enable client memory:

1. **The bare repo must be group-shared.** It's multi-writer: the NAS box pushes locally as its
   owner, WG clients push as the relay account. `onboard-memory.sh` now creates it with
   `git init --bare --shared=group`; for a repo that predates that, fix it in place:
   ```sh
   git --git-dir=<repo> config core.sharedRepository group
   find <repo> -type d -exec chmod g+rwxs {} + ; find <repo> -type f -exec chmod g+rw {} +
   ```
   The relay account must be in the repo owner's group (it already is, for the relay to traverse).
2. **Trust the repo for the git-shell account** (git's "dubious ownership" guard fires because the
   repo is owned by the NAS user, not the relay account):
   ```sh
   sudo -u <relay-account> git config --global --add safe.directory <repo>          # real path
   sudo -u <relay-account> git config --global --add safe.directory <symlink-path>  # e.g. /srv/claude-chats/memory.git
   ```
3. **Authorize each client key** with the `git-shell` forced-command line from step above, and make
   sure `git-shell` is installed on the receiver.

After these, every new client is fully covered by `onboard-memory.sh` + adding its one printed key.
