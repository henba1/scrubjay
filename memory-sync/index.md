# Cross-machine memory over its own git repo

Auto-memory (`~/.claude/projects/<project>/memory/`) wants git's **bidirectional merge + history** so the same project recalls memory written on any machine — so it rides its **own dedicated git repo**, separate from everything else. Where that repo lives mirrors your transcript backend, and the choice is a **custody trade-off** because memory holds **real filesystem paths**:

- **Self-hosted on the NAS** (`local` / `rsync-wg` backends) — a bare repo on your own hardware, reached over the existing WireGuard tunnel. **No third party ever sees it.** This is the default and the reason the setup exists: sensitive paths stay on gear you own. The cost is standing infrastructure — a NAS box, WireGuard, DDNS.
- **A private GitHub repo** (`git` backend) — a separate private `scrubjay-memory` repo, pushed with your normal GitHub SSH credentials (no dedicated key, no receiver step — simpler than the NAS path). The trade-off: your memory's real filesystem paths now sit in a **third party's** private repo (encrypted at rest, private, but off your hardware). Choose this if that's acceptable and you'd rather skip the NAS/WireGuard/DDNS wiring.

Either way it's the *same* mechanism below — only `SCRUBJAY_MEMORY_REMOTE` differs.

```
~/.claude/projects/<project>/memory/   ──symlink──►   $SCRUBJAY_MEMORY/<project>/   (local clone)
                                                              │  git pull --rebase  (SessionStart)
                                                              │  git push           (SessionEnd)
                                                              ▼
                                          $SCRUBJAY_MEMORY_REMOTE  =  bare repo on the NAS
                                          (local path on the NAS box · ssh://…over-WG on clients)
```

- `bin/memory-sync.sh pull|push` — clones on first use, then pulls/pushes. Best-effort, never blocks.
- `bin/claude-sync.sh` — symlinks each project's memory dir into the clone (**shared**, not per-host), and on first run migrates any legacy `scrubjay-data/memory/<host>/` content into it.
- Hooks: `sync-session.sh` pulls before linking; `log-session.sh` pushes at session end.

## Config keys (`~/.config/scrubjay/config`)

```
: "${SCRUBJAY_MEMORY:=$HOME/.scrubjay/scrubjay-memory}"          # local working clone
: "${SCRUBJAY_MEMORY_REMOTE:=...}"                              # the bare repo (see below)
```

If `SCRUBJAY_MEMORY_REMOTE` is unset, memory sync is **off** — the dir is just machine-local.

## Setup — automated

`bin/onboard-memory.sh` does all of the below, idempotently, on any machine — it's also run by `bin/onboard.sh` and exposed as the **`/sjmemory`** slash command. Run it once; re-running on an already-configured machine is a safe no-op:

```
bin/onboard-memory.sh        # or: /sjmemory   (from inside a session)
```

- **NAS box** (`local` backend): derives the bare-repo path from the NAS root, `git init --bare`s it if absent, sets the config keys, then clones + migrates legacy memory in + links the memory dirs.
- **WG client** (`rsync-wg` backend): generates a dedicated `scrubjay_memory_ed25519` key + a `scrubjay-memory` ssh alias (cribbing host/port from the `scrubjay-receiver` alias), sets the config keys, and **prints the one `authorized_keys` line** to add on the receiver (the server-side step stays manual — see below). Override anything via `MEM_BARE`, `MEM_GIT_USER`, `MEM_RECV_HOST`, etc.
- **GitHub-only** (`git` backend): points `SCRUBJAY_MEMORY_REMOTE` at a **separate private GitHub repo**, defaulting to a `scrubjay-memory` sibling of your other repos (derived from the `scrubjay-chats`/app clone's owner; override with `MEM_GIT_REMOTE`). No key or receiver step — it uses your normal GitHub SSH credentials. **You must create that empty private repo on GitHub first** (GitHub won't auto-create it); the first push populates it. `onboard-memory.sh` prints the privacy trade-off before wiring it.

## Setup — what it does by hand (reference)

NAS box (the bare repo lives **inside** the NAS storage folder, next to the transcript trees):

```
git init --bare /mnt/nas1/scrubjay-storage/memory.git          # the bare repo
# SCRUBJAY_MEMORY_REMOTE=/mnt/nas1/scrubjay-storage/memory.git     (a LOCAL path; no SSH hop here)
bin/memory-sync.sh pull && bin/claude-sync.sh && bin/memory-sync.sh push
```

`onboard-memory.sh` also installs a `post-receive` hook on the bare repo that checks the latest `main` out into a sibling **`scrubjay-storage/memory/`** — a human-browsable copy on the NAS, refreshed on every push (from this box or any client). The bare repo stays the sync hub; `memory/` is just a convenience view (don't edit it — it's overwritten on the next push).

WG client — git needs **full git-over-SSH**, and the transcript relay key can't be reused (its forced `rrsync -wo` command blocks git). `onboard-memory.sh` makes the key + alias; you add its public key on the receiver, restricted to git:

```
# on the receiver, in the git user's ~/.ssh/authorized_keys (printed for you by onboard-memory.sh):
command="git-shell -c \"$SSH_ORIGINAL_COMMAND\"",restrict ssh-ed25519 AAAA... <host> memory-git
# then on the client:  SCRUBJAY_MEMORY_REMOTE=scrubjay-memory:/srv/scrubjay-chats/memory.git
#   (/srv/scrubjay-chats is the receiver's symlink to the scrubjay-storage folder)
bin/memory-sync.sh pull && bin/claude-sync.sh
```

From then on the client pulls others' memory at session start and publishes its own at session end. Concurrent edits merge via `git pull --rebase --autostash`; a genuine conflict is left for you to resolve in the clone (memory files are small Markdown, so this is rare).

GitHub-only (`git` backend) — the simplest of the three: no bare repo, no key, no receiver admin. The **one prerequisite is yours to do first**, because GitHub won't create the repo for you:

```
# 1) create an EMPTY private repo on GitHub — a SEPARATE one, not scrubjay-chats. Name it scrubjay-memory
#    (that's the default onboard-memory.sh derives). e.g. with the gh CLI:
gh repo create <owner>/scrubjay-memory --private
# 2) then run the onboarder (or /sjmemory) on this machine — it derives the remote, sets the config
#    keys, and the first push populates the empty repo. Override the derived name with MEM_GIT_REMOTE.
MEM_GIT_REMOTE=git@github.com:<owner>/scrubjay-memory.git bin/onboard-memory.sh
```

Skip step 1 and the first push has nowhere to land — sync silently no-ops until the repo exists. Every other machine on the `git` backend just runs the onboarder and clones the same repo; no per-machine authorization (it rides your normal GitHub SSH credentials). Remember this repo now holds your memory's real filesystem paths — keep it **private**.

## Receiver one-time admin (per box, NOT per client)

The memory ride reuses the transcript relay's *connection* (same host, port, account, jump host) — the only thing that differs is the **key** (the receiver pins each key to one forced command: `rrsync -wo` for transcripts, `git-shell` for memory). So `onboard-memory.sh` on a WG client just generates a second key and an alias that inherits the relay's connection. Three things on the **receiver** are inherently manual (they need root and/or a *different* user than the one running onboard) and aren't auto-applied — do them once when you first enable client memory:

1. **The bare repo must be group-shared.** It's multi-writer: the NAS box pushes locally as its owner, WG clients push as the relay account. `onboard-memory.sh` now creates it with `git init --bare --shared=group`; for a repo that predates that, fix it in place:

   ```
   git --git-dir=<repo> config core.sharedRepository group
   find <repo> -type d -exec chmod g+rwxs {} + ; find <repo> -type f -exec chmod g+rw {} +
   ```

   The relay account must be in the repo owner's group (it already is, for the relay to traverse).

1. **Trust the repo for the git-shell account** (git's "dubious ownership" guard fires because the repo is owned by the NAS user, not the relay account):

   ```
   sudo -u <relay-account> git config --global --add safe.directory <repo>          # real path
   sudo -u <relay-account> git config --global --add safe.directory <symlink-path>  # e.g. /srv/scrubjay-chats/memory.git
   ```

1. **Authorize each client key** with the `git-shell` forced-command line from step above, and make sure `git-shell` is installed on the receiver.

After these, every new client is fully covered by `onboard-memory.sh` + adding its one printed key.
