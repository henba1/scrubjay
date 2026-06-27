# Cross-machine memory over a self-hosted NAS git repo

Auto-memory (`~/.claude/projects/<project>/memory/`) holds **sensitive paths**, so it must not ride
GitHub like the rest of the config — but it still wants git's **bidirectional merge + history** so the
same project recalls memory written on any machine. The solution: a dedicated **bare git repo on the
NAS**, reached over the existing WireGuard tunnel. No third party ever sees it.

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

## Setup — what it does by hand (reference)

NAS box:
```sh
git init --bare /media/<you>/NAS1/Claude-Code-memory.git        # the bare repo
# DOTCLAUDE_MEMORY_REMOTE=/media/<you>/NAS1/Claude-Code-memory.git   (a LOCAL path; no SSH hop here)
bin/memory-sync.sh pull && bin/claude-sync.sh && bin/memory-sync.sh push
```

WG client — git needs **full git-over-SSH**, and the transcript relay key can't be reused (its
forced `rrsync -wo` command blocks git). `onboard-memory.sh` makes the key + alias; you add its
public key on the receiver, restricted to git:

```sh
# on the receiver, in the git user's ~/.ssh/authorized_keys (printed for you by onboard-memory.sh):
command="git-shell -c \"$SSH_ORIGINAL_COMMAND\"",restrict ssh-ed25519 AAAA... <host> memory-git
# then on the client:  DOTCLAUDE_MEMORY_REMOTE=claude-memory:/srv/Claude-Code-memory.git
bin/memory-sync.sh pull && bin/claude-sync.sh
```

From then on the client pulls others' memory at session start and publishes its own at session end.
Concurrent edits merge via `git pull --rebase --autostash`; a genuine conflict is left for you to
resolve in the clone (memory files are small Markdown, so this is rare).
