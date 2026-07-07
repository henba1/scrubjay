<div align="center">

<img src="docs/banner.png" alt="dotclaude — Claude sync engine" width="100%">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-mkdocs--material-2094f3.svg)](https://henba1.github.io/dotclaude/)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-d97757.svg)](https://claude.ai/code)
[![shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)](#)

</div>

# dotclaude

The **app/logic** for syncing [Claude Code](https://claude.ai/code) across machines —
one configuration, applied to every machine, with each session's records relayed to your
own NAS. Your personal content is kept in *separate* repos so this one can be
shared/public without leaking anything:

| Repo | Role | Visibility |
|---|---|---|
| **dotclaude** (this) | scripts, hooks, docs — the logic | public-able |
| **dotclaude-data** | `hosts/`, `settings/`, `claude-md/`, `templates/`, `memory/`, `logs/` | private |
| **claude-chats** | full chat transcripts (`.jsonl`), relayed off each machine | private |

![dotclaude — system overview](docs/overview.svg)

<sub>Diagram source: [`docs/overview.dot`](docs/overview.dot) — `dot -Tsvg docs/overview.dot -o docs/overview.svg`.</sub>

> **Flow:** `dotclaude` (logic) + `dotclaude-data` (your config) → applied into each
> machine's `~/.claude` by `claude-sync.sh`. On `SessionEnd` a hook appends a one-line
> entry to `dotclaude-data/logs/<host>.log` *and* relays the session (transcript, subagents,
> plans) off the machine via a pluggable backend — either peer-to-peer to your own NAS (over
> WireGuard), or to a private `claude-chats` repo on GitHub if you'd rather not run storage of
> your own. Top-level is keyed by machine so envs stay distinct and Claude can re-tailor one
> host's rules for another.

## The core idea: two kinds of sync

Everything dotclaude moves is one of two things — and which one it is decides the *mechanism*:

| Semantic | Mechanism | What it fits |
|---|---|---|
| **Shared / bidirectional** — same content everywhere, edits *merge* | **git** (pull + push) | things you *author*: `CLAUDE.md`, `commands`, `agents`, `settings`, **memory** |
| **Archive / one-way** — machine → NAS, never read back | **rsync** (peer-to-peer) | *records*: transcripts, subagents, plans, `readable/`, history |

The orthogonal axis is **privacy**: anything sensitive goes straight to your own NAS, never a
third party. In one sentence — **author-vs-record picks git-vs-rsync; sensitive-vs-not picks
NAS-vs-GitHub.** The full design is in [Concepts](https://henba1.github.io/dotclaude/concepts/).

## Quick start

**With Claude Code** — clone, open Claude in the clone, and ask it to set things up. It reads
[`AGENTS.md`](AGENTS.md), gathers your choices, and drives the onboarder:

```sh
git clone git@github.com:<your-gh-user>/dotclaude.git ~/.dotclaude/dotclaude
cd ~/.dotclaude/dotclaude && claude
# then: "set up dotclaude on this machine"
```

**By hand** — run the interactive onboarder directly:

```sh
git clone git@github.com:<your-gh-user>/dotclaude.git ~/.dotclaude/dotclaude
~/.dotclaude/dotclaude/bin/onboard.sh
```

It clones the sibling data repos, writes the machine-local pointer, registers the host, applies
config, and (for the peer-to-peer backends) prints one `authorized_keys` line to paste on the
receiver — the single manual step, by design. Prereqs: `bash`, `jq`, `git`, an SSH key on GitHub;
no root. Full walkthrough: [Onboarding](https://henba1.github.io/dotclaude/onboarding/).

## Documentation

Full docs — [**henba1.github.io/dotclaude**](https://henba1.github.io/dotclaude/):

- [**Concepts**](https://henba1.github.io/dotclaude/concepts/) — the two-kinds-of-sync model and what lives in the database.
- [**Onboarding**](https://henba1.github.io/dotclaude/onboarding/) — install on a new machine, the repo layout, and machine-local pointers.
- [**Day-to-day**](https://henba1.github.io/dotclaude/day-to-day/) — the hooks that keep it hands-off, finding a past chat, troubleshooting.
- [**Query the archive (MCP)**](https://henba1.github.io/dotclaude/archive-mcp/) — recall a past session by *topic* from inside a live Claude session.
- [**Slash commands**](https://henba1.github.io/dotclaude/slash-commands/) — the `/dc*` command reference.
- [**Transcripts: relay + NAS**](https://henba1.github.io/dotclaude/transports/) — the peer-to-peer paths (WireGuard / SSH) to your own NAS.
- [**Reference**](https://henba1.github.io/dotclaude/reference/) — the by-hand command cheatsheet and environment toggles.

The docs also publish an [`llms.txt`](https://henba1.github.io/dotclaude/llms.txt) index for agents.

## License

[MIT](LICENSE) © 2026 Hendrik
