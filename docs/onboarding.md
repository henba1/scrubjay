# Onboarding

## The three repos, and which ones are yours

scrubjay is the **app** — public, and you run it straight from upstream. **You don't fork it.**
It updates itself with `git pull`, which is why it must be a `git clone` and not an unpacked
source tarball (an archive has no `.git`, so the self-update silently never runs; the app tells
you so at session start if you get this wrong).

Your **content** lives in separate **private** repos under your own GitHub account:

| Repo | When | Who creates it |
|---|---|---|
| `scrubjay-data` | always | `bin/sj-bootstrap.sh`, seeded from `skeleton/data` |
| `scrubjay-chats` | `git` backend | `bin/sj-bootstrap.sh` |
| `scrubjay-memory` | cross-machine memory on the `git` backend | `bin/onboard-memory.sh` |

The onboarder asks which GitHub account owns them (preset it with `SCRUBJAY_OWNER`) and creates
any that are missing via the [`gh`](https://cli.github.com) CLI. Without `gh` it prints the exact
`gh repo create` commands and stops — nothing is created behind your back.

!!! note "Why the app's origin doesn't decide where your data lives"
    They're deliberately decoupled. Otherwise cloning the public app repo would make the onboarder
    reach for the *maintainer's* private `scrubjay-data`. It refuses to treat the upstream account
    as yours, and says so.

## Install with Claude Code (agent-assisted)

The fastest path if you already run Claude Code: clone this repo, open Claude *inside*
the clone, and ask it to set the machine up.

```sh
git clone git@github.com:henba1/scrubjay.git ~/.scrubjay/scrubjay
cd ~/.scrubjay/scrubjay
claude
```

Then, in the session:

> **set up scrubjay on this machine**

Claude reads [`AGENTS.md`](https://github.com/henba1/scrubjay/blob/main/AGENTS.md) at
the repo root, gathers your relay-backend choice and receiver details in chat, and drives
`bin/onboard.sh` for you — then surfaces the one manual step it deliberately can't do:
pasting the printed `authorized_keys` line on the receiver (see the warning below).

## Fast path — interactive script

Clone this repo, then run `bin/onboard.sh`. It checks deps (and offers to install Claude
Code if missing), creates + seeds your private data repos, writes the machine-local pointer,
registers the host and applies config, and — for the `rsync-wg` backend — optionally
generates the dedicated relay SSH key, adds the `scrubjay-receiver` ssh-alias, and prints
the exact `authorized_keys` line to paste on the receiver. It's re-runnable and every
prompt has a default (or preset it via env, e.g. `SCRUBJAY_OWNER`, `SCRUBJAY_BACKEND`):

```sh
git clone git@github.com:henba1/scrubjay.git ~/.scrubjay/scrubjay
~/.scrubjay/scrubjay/bin/onboard.sh
```

Run `bin/sj-bootstrap.sh` on its own to create/seed the private repos without onboarding, and
`bin/onboard.sh --version` to see which commit you're on.

!!! warning "One manual step the script can't do for you — authorize the new host on the receiver."
    For the peer-to-peer backends, `onboard.sh` (transcripts) and `onboard-memory.sh` (memory) each
    **print an `authorized_keys` line**; you must paste it into the receiver account's
    `~/.ssh/authorized_keys` (e.g. `scrubjay-rx` on the NAS box, needs sudo). This is deliberate — a new
    machine must not be able to self-authorize; granting it access requires a human with root on the
    receiver. Each line is locked to one forced command (`rrsync -wo` for transcripts, `git-shell` for
    memory), so a leaked key can't get a shell or read the archive back. Until you add the line, that
    host's sync silently no-ops. (Receiver also needs a one-time `safe.directory` trust for the memory
    repo — see [memory-sync.md](memory-sync.md).)

??? note "Manual steps (what the script automates)"
    ```sh
    git clone git@github.com:<your-gh-user>/scrubjay.git      ~/.scrubjay/scrubjay
    git clone git@github.com:<your-gh-user>/scrubjay-data.git ~/.scrubjay/scrubjay-data
    git clone git@github.com:<your-gh-user>/scrubjay-chats.git   ~/.scrubjay/scrubjay-chats   # if syncing transcripts

    mkdir -p ~/.config/scrubjay && cat > ~/.config/scrubjay/config <<'EOF'
    : "${SCRUBJAY_DATA:=$HOME/.scrubjay/scrubjay-data}"
    : "${SCRUBJAY_CHATS:=$HOME/.scrubjay/scrubjay-chats}"
    : "${SCRUBJAY_TRANSCRIPT_BACKEND:=git}"
    EOF

    ~/.scrubjay/scrubjay/bin/claude-register-host.sh --host <name>   # scaffold + pin + index
    # review ~/.scrubjay/scrubjay-data/hosts/<name>/
    ~/.scrubjay/scrubjay/bin/claude-sync.sh                          # apply into ~/.claude
    git -C ~/.scrubjay/scrubjay-data add -A && git -C ~/.scrubjay/scrubjay-data commit -m "host <name>" && git -C ~/.scrubjay/scrubjay-data push
    ```

    `~/.scrubjay/` keeps the machinery out of your project workspace; the clone location is
    otherwise arbitrary (it's only referenced via the pointer file below).

Prereqs: `bash`, `jq`, `git`, an SSH key on GitHub. No root.

## Pointers (machine-local)

The app finds your data/transcript repos via `~/.config/scrubjay/config` (env overrides):

```sh
: "${SCRUBJAY_DATA:=$HOME/.scrubjay/scrubjay-data}"
: "${SCRUBJAY_CHATS:=$HOME/.scrubjay/scrubjay-chats}"
: "${SCRUBJAY_TRANSCRIPT_BACKEND:=git}"
```

Host identity is pinned separately in `~/.config/scrubjay/host` (because `hostname -s`
is transient on HPC login nodes).

## Layout (this repo — app only)

```
bin/
  onboard.sh             # interactive new-machine setup (deps, clone, config, register, sync, relay key, memory); also the /sjonboard command
  onboard-memory.sh      # enable/repair cross-machine memory on this machine (idempotent; the /sjmemory command)
  lib.sh                 # shared helpers: host + data/chats pointers
  claude-sync.sh         # apply data-repo config into ~/.claude (symlinks + merged settings)
  claude-index-chats.sh  # write scrubjay-data/hosts/<host>/chats.index.json
  claude-register-host.sh# scaffold a new host into the data repo
  ship-transcript.sh     # relay a session (transcript + subagents + plans + readable + history + tasks) via the selected backend
  memory-sync.sh         # pull/push cross-machine memory via its own NAS-hosted git repo (over WireGuard)
  render-transcript.sh   # render a .jsonl as a human-readable Markdown session log (full tool stream)
  backfill-readable.sh   # (one-off) build the readable/ tree for transcripts already on the NAS
  pull-and-mirror.sh     # (mirror host) pull scrubjay-chats -> NAS
  onboard-hpc-client.sh  # set up an HPC node to ship over SSH/ProxyJump (no-WG path): key+ssh_config+pointer
  onboard-edge-node.sh   # set up the home edge/bastion (jump user, restricted keys, sshd scope, nft allowlist)
  onboard-mcp-client.sh  # client w/o the archive: key+ssh alias + SCRUBJAY_MCP_REMOTE to query the archive host over SSH
  sjmcp-serve.sh         # receiver-side forced command: runs the MCP server on the archive host, pipes stdio over SSH
hooks/
  sync-session.sh        # SessionStart hook: pull data repo + pull memory repo + claude-sync (auto-fresh config)
  log-session.sh         # SessionEnd hook: log line + refresh index + push memory + ship session
  publish-now.sh         # manual SessionEnd-on-demand (the /sjlog command); reconstructs the hook payload
  transports/git.sh      # backend: push to the private scrubjay-chats repo on GitHub (zero-infra; optional NAS mirror)
  transports/rsync-wg.sh # backend: peer-to-peer rsync over WireGuard (the NAS receiver)
  transports/local.sh    # backend: local copy (the box that has the NAS mounted)
mcp/
  sjmcp_server.py        # read-only MCP server over the archive (the /sjrecall|/sjfind|/sjbrowse engine; `uv run --script`)
skeleton/host/           # template copied when registering a new machine
docs/                    # diagrams (overview + transport-wg/-ssh .dot/.svg) and this documentation site
```

## Re-home the scrubjay clones

Moving the machinery (e.g. out of `~/code` into `~/.scrubjay`) is machine-local — nothing
to commit. See the [Reference cheatsheet](reference.md#re-home-the-scrubjay-clones).
