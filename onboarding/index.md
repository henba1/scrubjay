# Onboarding

## Install with Claude Code (agent-assisted)

The fastest path if you already run Claude Code: clone this repo, open Claude *inside* the clone, and ask it to set the machine up.

```
git clone git@github.com:<your-gh-user>/dotclaude.git ~/.dotclaude/dotclaude
cd ~/.dotclaude/dotclaude
claude
```

Then, in the session:

> **set up dotclaude on this machine**

Claude reads [`AGENTS.md`](https://github.com/henba1/dotclaude/blob/main/AGENTS.md) at the repo root, gathers your relay-backend choice and receiver details in chat, and drives `bin/onboard.sh` for you — then surfaces the one manual step it deliberately can't do: pasting the printed `authorized_keys` line on the receiver (see the warning below).

## Fast path — interactive script

Clone this repo, then run `bin/onboard.sh`. It checks deps (and offers to install Claude Code if missing), clones the sibling data repos, writes the machine-local pointer, registers the host and applies config, and — for the `rsync-wg` backend — optionally generates the dedicated relay SSH key, adds the `claude-receiver` ssh-alias, and prints the exact `authorized_keys` line to paste on the receiver. It's re-runnable and every prompt has a default (or preset it via env, e.g. `DOTCLAUDE_BACKEND`):

```
git clone git@github.com:<your-gh-user>/dotclaude.git ~/.dotclaude/dotclaude
~/.dotclaude/dotclaude/bin/onboard.sh
```

One manual step the script can't do for you — authorize the new host on the receiver.

For the peer-to-peer backends, `onboard.sh` (transcripts) and `onboard-memory.sh` (memory) each **print an `authorized_keys` line**; you must paste it into the receiver account's `~/.ssh/authorized_keys` (e.g. `claude-rx` on the NAS box, needs sudo). This is deliberate — a new machine must not be able to self-authorize; granting it access requires a human with root on the receiver. Each line is locked to one forced command (`rrsync -wo` for transcripts, `git-shell` for memory), so a leaked key can't get a shell or read the archive back. Until you add the line, that host's sync silently no-ops. (Receiver also needs a one-time `safe.directory` trust for the memory repo — see [memory-sync.md](https://henba1.github.io/dotclaude/memory-sync/index.md).)

Manual steps (what the script automates)

```
git clone git@github.com:<your-gh-user>/dotclaude.git      ~/.dotclaude/dotclaude
git clone git@github.com:<your-gh-user>/dotclaude-data.git ~/.dotclaude/dotclaude-data
git clone git@github.com:<your-gh-user>/claude-chats.git   ~/.dotclaude/claude-chats   # if syncing transcripts

mkdir -p ~/.config/dotclaude && cat > ~/.config/dotclaude/config <<'EOF'
: "${DOTCLAUDE_DATA:=$HOME/.dotclaude/dotclaude-data}"
: "${DOTCLAUDE_CHATS:=$HOME/.dotclaude/claude-chats}"
: "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
EOF

~/.dotclaude/dotclaude/bin/claude-register-host.sh --host <name>   # scaffold + pin + index
# review ~/.dotclaude/dotclaude-data/hosts/<name>/
~/.dotclaude/dotclaude/bin/claude-sync.sh                          # apply into ~/.claude
git -C ~/.dotclaude/dotclaude-data add -A && git -C ~/.dotclaude/dotclaude-data commit -m "host <name>" && git -C ~/.dotclaude/dotclaude-data push
```

`~/.dotclaude/` keeps the machinery out of your project workspace; the clone location is otherwise arbitrary (it's only referenced via the pointer file below).

Prereqs: `bash`, `jq`, `git`, an SSH key on GitHub. No root.

## Pointers (machine-local)

The app finds your data/transcript repos via `~/.config/dotclaude/config` (env overrides):

```
: "${DOTCLAUDE_DATA:=$HOME/.dotclaude/dotclaude-data}"
: "${DOTCLAUDE_CHATS:=$HOME/.dotclaude/claude-chats}"
: "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
```

Host identity is pinned separately in `~/.config/dotclaude/host` (because `hostname -s` is transient on HPC login nodes).

## Layout (this repo — app only)

```
bin/
  onboard.sh             # interactive new-machine setup (deps, clone, config, register, sync, relay key, memory); also the /dconboard command
  onboard-memory.sh      # enable/repair cross-machine memory on this machine (idempotent; the /dcmemory command)
  lib.sh                 # shared helpers: host + data/chats pointers
  claude-sync.sh         # apply data-repo config into ~/.claude (symlinks + merged settings)
  claude-index-chats.sh  # write dotclaude-data/hosts/<host>/chats.index.json
  claude-register-host.sh# scaffold a new host into the data repo
  ship-transcript.sh     # relay a session (transcript + subagents + plans + readable + history + tasks) via the selected backend
  memory-sync.sh         # pull/push cross-machine memory via its own NAS-hosted git repo (over WireGuard)
  render-transcript.sh   # render a .jsonl as a human-readable Markdown session log (full tool stream)
  backfill-readable.sh   # (one-off) build the readable/ tree for transcripts already on the NAS
  pull-and-mirror.sh     # (mirror host) pull claude-chats -> NAS
  onboard-hpc-client.sh  # set up an HPC node to ship over SSH/ProxyJump (no-WG path): key+ssh_config+pointer
  onboard-edge-node.sh   # set up the home edge/bastion (jump user, restricted keys, sshd scope, nft allowlist)
  onboard-mcp-client.sh  # client w/o the archive: key+ssh alias + DOTCLAUDE_MCP_REMOTE to query the archive host over SSH
  dcmcp-serve.sh         # receiver-side forced command: runs the MCP server on the archive host, pipes stdio over SSH
hooks/
  sync-session.sh        # SessionStart hook: pull data repo + pull memory repo + claude-sync (auto-fresh config)
  log-session.sh         # SessionEnd hook: log line + refresh index + push memory + ship session
  publish-now.sh         # manual SessionEnd-on-demand (the /dclog command); reconstructs the hook payload
  transports/git.sh      # backend: push to the private claude-chats repo on GitHub (zero-infra; optional NAS mirror)
  transports/rsync-wg.sh # backend: peer-to-peer rsync over WireGuard (the NAS receiver)
  transports/local.sh    # backend: local copy (the box that has the NAS mounted)
mcp/
  dcmcp_server.py        # read-only MCP server over the archive (the /dcrecall|/dcfind|/dcbrowse engine; `uv run --script`)
skeleton/host/           # template copied when registering a new machine
docs/                    # diagrams (overview + transport-wg/-ssh .dot/.svg) and this documentation site
```

## Re-home the dotclaude clones

Moving the machinery (e.g. out of `~/code` into `~/.dotclaude`) is machine-local — nothing to commit. See the [Reference cheatsheet](https://henba1.github.io/dotclaude/reference/#re-home-the-dotclaude-clones).
