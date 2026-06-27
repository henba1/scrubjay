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

## One-time setup on the NAS box (the machine that has the NAS mounted)

```sh
git init --bare /media/<you>/NAS1/Claude-Code-memory.git        # the bare repo
# point this machine at it via a LOCAL path (no SSH hop needed here):
#   DOTCLAUDE_MEMORY_REMOTE=/media/<you>/NAS1/Claude-Code-memory.git
bin/memory-sync.sh pull       # clone it (empty is fine)
bin/claude-sync.sh            # migrate legacy memory in + repoint symlinks
bin/memory-sync.sh push       # publish
```

## Onboarding a client (over WireGuard)

A client reaches the bare repo with **full git-over-SSH** — note the transcript relay key uses a
forced `rrsync -wo` command and therefore **cannot** be reused for git. Add a separate key (optionally
restricted to `git-shell`) authorized on the NAS box, reachable through the same WG `claude-receiver`
SSH alias, then:

```sh
# ~/.config/dotclaude/config on the client:
: "${DOTCLAUDE_MEMORY_REMOTE:=ssh://<user>@claude-receiver/media/<you>/NAS1/Claude-Code-memory.git}"
bin/memory-sync.sh pull && bin/claude-sync.sh
```

From then on the client pulls others' memory at session start and publishes its own at session end.
Concurrent edits merge via `git pull --rebase --autostash`; a genuine conflict is left for you to
resolve in the clone (memory files are small Markdown, so this is rare).
