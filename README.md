<div align="center">

<img src="docs/banner.png" alt="scrubjay — recall what · where · when" width="100%">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-mkdocs--material-2094f3.svg)](https://henba1.github.io/scrubjay/)
[![Built for opencode](https://img.shields.io/badge/built%20for-opencode-000000.svg)](https://opencode.ai)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-d97757.svg)](https://claude.ai/code)
[![shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)](#)

</div>

# scrubjay

**Your AI coding sessions and setup, on every machine you own.**

You use a coding agent — [Claude Code](https://claude.ai/code), [opencode](https://opencode.ai),
[codex](https://developers.openai.com/codex/) — on more than one machine. So you have two problems
you probably solve by hand today:

1. **Your setup doesn't travel.** The instructions, commands and agents you tuned on the laptop
   aren't on the workstation.
2. **Your chats don't travel — and then they're gone.** Yesterday's session, the one where you
   worked out the tricky thing, is on the other machine. Or it aged out.

scrubjay fixes both, and keeps it all on hardware you own.

- **One config, every machine.** Write your instructions, commands and agents once. Every machine
  picks them up — and so does every agent, since the same setup lands in Claude Code *and* opencode.
- **Every session archived, and searchable in plain English.** When a session ends it's copied to
  your own NAS automatically. Later you ask *"what was that fix for the auth timeout?"* and get the
  real conversation back — whichever machine and whichever agent it happened on.
- **Yours.** Your config and chats live in private repos on your own account; transcripts go
  straight to your own storage. This repo is only the machinery, which is why it can be public.

Three repos, so the machinery can be public without leaking anything you wrote:

| Repo | What's in it | Visibility |
|---|---|---|
| **scrubjay** (this) | the scripts, hooks and docs — the logic, no content | public |
| **scrubjay-data** | your config: instructions, commands, agents, settings, memory, session log | private, your account |
| **scrubjay-chats** | your full transcripts — only if you pick the GitHub relay instead of a NAS | private, your account |

![scrubjay — system overview](docs/overview.svg)

<sub>Diagram source: [`docs/overview.dot`](docs/overview.dot) — `dot -Tsvg docs/overview.dot -o docs/overview.svg`.</sub>

> **How it flows.** When a session *starts*, scrubjay pulls your config out of `scrubjay-data` and
> applies it into whichever agents this machine has. When a session *ends*, a hook writes one line
> to a shared log ("what ran, where, when") and ships the session itself — transcript, subagents,
> plans — off the machine. Where it ships is your choice: peer-to-peer to your own NAS (over
> WireGuard or a local mount), or to a private GitHub repo if you'd rather not run storage. The
> archive is keyed by machine, so each one's history stays its own and your agent can adapt one
> machine's rules for another.

## The core idea: two kinds of sync

Everything scrubjay moves is one of two things — and which one it is decides the *mechanism*:

| Semantic | Mechanism | What it fits |
|---|---|---|
| **Shared / bidirectional** — same content everywhere, edits *merge* | **git** (pull + push) | things you *author*: `CLAUDE.md`, `commands`, `agents`, `settings`, **memory** |
| **Archive / one-way** — machine → NAS, never read back | **rsync** (peer-to-peer) | *records*: transcripts, subagents, plans, `readable/`, history |

The orthogonal axis is **privacy**: anything sensitive goes straight to your own NAS, never a
third party. In one sentence — **author-vs-record picks git-vs-rsync; sensitive-vs-not picks
NAS-vs-GitHub.** The full design is in [Concepts](https://henba1.github.io/scrubjay/concepts/).

## Quick start

**No fork needed.** Clone this repo straight from upstream — it's the app, and it updates itself
by `git pull`. Your *content* lives in private repos under your **own** GitHub account, which the
onboarder creates for you (`scrubjay-data`, plus `scrubjay-chats` on the `git` backend).

**With Claude Code** — clone, open Claude in the clone, and ask it to set things up. It reads
[`AGENTS.md`](AGENTS.md), gathers your choices, and drives the onboarder:

```sh
git clone git@github.com:henba1/scrubjay.git ~/.scrubjay/scrubjay
cd ~/.scrubjay/scrubjay && claude
# then: "set up scrubjay on this machine"
```

**By hand** — run the interactive onboarder directly:

```sh
git clone git@github.com:henba1/scrubjay.git ~/.scrubjay/scrubjay
~/.scrubjay/scrubjay/bin/onboard.sh          # asks for your GitHub account (or set SCRUBJAY_OWNER)
```

It creates and seeds your private repos, writes the machine-local pointer, registers the host,
applies config, and (for the peer-to-peer backends) prints one `authorized_keys` line to paste on
the receiver — the single manual step, by design.

Prereqs: `bash`, `jq`, `git`, an SSH key on GitHub, and the [`gh`](https://cli.github.com) CLI to
create the private repos (without it, the onboarder prints the exact `gh repo create` commands and
stops). No root. Install with `git clone`, **not** a source tarball — the app self-updates by
pulling, so an unpacked archive can never update itself. Full walkthrough:
[Onboarding](https://henba1.github.io/scrubjay/onboarding/).

## Documentation

Full docs — [**henba1.github.io/scrubjay**](https://henba1.github.io/scrubjay/):

- [**Concepts**](https://henba1.github.io/scrubjay/concepts/) — the two-kinds-of-sync model and what lives in the database.
- [**Harnesses**](https://henba1.github.io/scrubjay/harnesses/) — Claude Code, opencode, codex: what's supported, and what syncs into opencode.
- [**Onboarding**](https://henba1.github.io/scrubjay/onboarding/) — install on a new machine, the repo layout, and machine-local pointers.
- [**Day-to-day**](https://henba1.github.io/scrubjay/day-to-day/) — the hooks that keep it hands-off, finding a past chat, troubleshooting.
- [**Query the archive (MCP)**](https://henba1.github.io/scrubjay/archive-mcp/) — recall a past session by *topic* from inside a live Claude session.
- [**Slash commands**](https://henba1.github.io/scrubjay/slash-commands/) — the `/dc*` command reference.
- [**Transcripts: relay + NAS**](https://henba1.github.io/scrubjay/transports/) — the peer-to-peer paths (WireGuard / SSH) to your own NAS.
- [**Reference**](https://henba1.github.io/scrubjay/reference/) — the by-hand command cheatsheet and environment toggles.

The docs also publish an [`llms.txt`](https://henba1.github.io/scrubjay/llms.txt) index for agents.

## License

[MIT](LICENSE) © 2026 Hendrik
