# dotclaude

The **app/logic** for syncing [Claude Code](https://claude.ai/code) across machines. Your
personal content is kept in *separate* repos so this one can be shared/public without
leaking anything:

| Repo | Role | Visibility |
|---|---|---|
| **dotclaude** (this) | scripts, hooks, docs — the logic | public-able |
| **dotclaude-data** | `hosts/`, `settings/`, `claude-md/`, `templates/`, `memory/`, `logs/` | private |
| **claude-chats** | full chat transcripts (`.jsonl`), relayed off each machine | private |

![dotclaude — system overview](docs/overview.svg)

<sub>Diagram source: [`docs/overview.dot`](docs/overview.dot) — `dot -Tsvg docs/overview.dot -o docs/overview.svg`.</sub>

> **Flow:** `dotclaude` (logic) + `dotclaude-data` (your config) → applied into each
> machine's `~/.claude` by `claude-sync.sh`. On `SessionEnd` a hook appends a one-line
> entry to `dotclaude-data/logs/<host>.log` *and* ships the full transcript to
> `claude-chats`; a Raspberry Pi mirrors that into the NAS. Top-level is keyed by machine
> so envs stay distinct and Claude can re-tailor one host's rules for another.

## Layout (this repo — app only)

```
bin/
  lib.sh                 # shared helpers: host + data/chats pointers
  claude-sync.sh         # apply data-repo config into ~/.claude (symlinks + merged settings)
  claude-index-chats.sh  # write dotclaude-data/hosts/<host>/chats.index.json
  claude-register-host.sh# scaffold a new host into the data repo
  ship-transcript.sh     # relay a transcript via the selected backend
  pull-and-mirror.sh     # (Pi) pull claude-chats -> NAS
hooks/
  log-session.sh         # SessionEnd hook: log line + ship transcript
  transports/git.sh      # transcript backend: git (current)
  transports/rsync-wg.sh # transcript backend: WireGuard rsync (upcoming, stub)
skeleton/host/           # template copied when registering a new machine
docs/                    # overview diagram, raspberry-pi.md, transcript-transport.md
```

## Pointers (machine-local)

The app finds your data/transcript repos via `~/.config/dotclaude/config` (env overrides):

```sh
: "${DOTCLAUDE_DATA:=$HOME/code/dotclaude-data}"
: "${DOTCLAUDE_CHATS:=$HOME/code/claude-chats}"
: "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
```

Host identity is pinned separately in `~/.config/dotclaude/host` (because `hostname -s`
is transient on HPC login nodes).

## Onboard a new machine

```sh
git clone git@github.com:henba1/dotclaude.git      ~/code/dotclaude
git clone git@github.com:henba1/dotclaude-data.git ~/code/dotclaude-data
git clone git@github.com:henba1/claude-chats.git   ~/code/claude-chats   # if syncing transcripts

mkdir -p ~/.config/dotclaude && cat > ~/.config/dotclaude/config <<'EOF'
: "${DOTCLAUDE_DATA:=$HOME/code/dotclaude-data}"
: "${DOTCLAUDE_CHATS:=$HOME/code/claude-chats}"
: "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
EOF

~/code/dotclaude/bin/claude-register-host.sh --host <name>   # scaffold + pin + index
# review ~/code/dotclaude-data/hosts/<name>/
~/code/dotclaude/bin/claude-sync.sh                          # apply into ~/.claude
git -C ~/code/dotclaude-data add -A && git -C ~/code/dotclaude-data commit -m "host <name>" && git -C ~/code/dotclaude-data push
```

Prereqs: `bash`, `jq`, `git`, an SSH key on GitHub. No root.

## Day-to-day

```sh
bin/claude-sync.sh         # re-apply after pulling config changes (idempotent)
bin/claude-index-chats.sh  # refresh this host's chats.index.json
```

## Find a past chat

Every session is logged by the `SessionEnd` hook to `dotclaude-data/logs/<host>.log`
(one line: `time | host | cwd | "first prompt" | session=id`) and pushed, so all
machines' histories are searchable from any clone of the data repo:

```sh
git -C ~/code/dotclaude-data pull
grep -i foolbox ~/code/dotclaude-data/logs/*.log
```

The full transcript (the `.jsonl`) lives in `claude-chats` / on the NAS under
`<host>/<slug>/<session>.jsonl`.

## Transcripts: relay + NAS

`SessionEnd` ships each transcript via a **pluggable backend** (`ship-transcript.sh`).
Current backend `git` pushes to `claude-chats`; a Pi mirrors it to the NAS
([`docs/raspberry-pi.md`](docs/raspberry-pi.md)). The transport is designed to switch to
**peer-to-peer rsync over WireGuard** (no third-party server) —
[`docs/transcript-transport.md`](docs/transcript-transport.md).

## Cross-machine tailoring with Claude

Everything is plain Markdown/JSON, so from any project you can ask Claude: *"read
`dotclaude-data/hosts/<other>/` and adapt its rules for this box"* — it reads one host's
config and writes another's.
