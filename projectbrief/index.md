# Project brief

scrubjay's primary function is to sync context — like prompts, agent identities and artefacts such as session transcripts — for coding agents such as Claude Code and those deployed through the opencode harness (e.g. plans, memories, transcripts, `CLAUDE.md` / `AGENTS.md`), and to make them accessible and usable from all hosts in a scrubjay network. scrubjay's design follows privacy-first principles.

The payoff is time and tokens: context a previous session already worked out stays findable and reusable, instead of being rebuilt from scratch over several turns on whichever machine you happen to be sitting at.

## Why it exists

I run my own home infrastructure (e.g. self-hosted Nextcloud) with multiple boxes, and ran into three problems, each of which cost me time and induced overhead and friction in my workflows.

**Setup drift.** Setting up Claude Code and opencode the way I like them on all machines was time consuming, and once each box was set up correctly, they still drifted apart as I changed things on one machine and not the others.

**Context that does not travel.** The context from sessions did not propagate to all hosts, so I had to drag it along manually — copying transcripts, and keeping track of the harness, root and host the session took place in.

**Findability.** I was manually browsing via the Claude Code and opencode global lookup functions on multiple hosts, or through artefacts like GitHub issues and PR descriptions, to find specific conversation snippets, prompts, or my own user turns that I wanted to continue and expand upon. Sometimes I had an idea while working, or an issue surfaced that I did not pursue in that session — and later I wanted to build or tackle it. That manual process was very time intensive and not very efficient, as often I could not even find what I was looking for. As a result, not only was my time used sub-optimally, overall token usage also increased: I had to rebuild the model context from scratch, sometimes over multiple turns, for something a previous model had already worked out but which had got lost in the noise.

## Design goals

scrubjay's design goals follow two tenets:

1. **Efficiency.** Valuable data and insights are often hidden in produced context such as session transcripts. We want to use this rather than lose it, and thereby improve time and token efficiency.
1. **Flexibility.** A session should be indexed and made usable independently of where that session took place along the directory, host, or harness dimension. It should be as easy to search and resume a conversation from a different host and/or harness as on the machine and/or harness where the conversation started. Environment setups (prompts, `CLAUDE.md`) should travel easily across host boundaries. Ideally, it should not matter from where you pick up the work you began on machine X.

## Central feature: syncing and book-keeping

Everything scrubjay moves is one of two things, and which one it is decides how it moves:

|               | Things you **author**                                                    | Things that **happen**                                    |
| ------------- | ------------------------------------------------------------------------ | --------------------------------------------------------- |
| *For example* | prompts, agent identities, commands, settings, `CLAUDE.md` / `AGENTS.md` | transcripts, plans, memories, task and file history       |
| *Shape*       | small, hand-edited, wants to merge                                       | large, machine-generated, append-only, never edited twice |
| *So it uses*  | **git** — every machine, both ways                                       | **one-way relay** to storage you own                      |

This is why transcripts do not live in the config repo: they are records, not authored files, and they only ever travel machine → storage. [Concepts](https://henba1.github.io/scrubjay/concepts/index.md) has the long version, including the second axis — sensitive vs. not — that decides NAS vs. GitHub.

Session syncing needs a single source of truth. Currently this is facilitated either through a third-party GitHub repo or — for privacy and potentially compliance reasons, and preferably — through a NAS on a self-hosted box running scrubjay, which can also be accessed from other networks through WireGuard tunnels.

Topologically this is hub-and-spoke, or *centralized peer-to-peer*: the storage node is the central entity necessary to provide the service. What makes it peer-to-peer is the data path rather than the shape — records travel directly from your machines to hardware you control, with no third party in between. If you are concerned about downtime, reliability and the maintenance that self-hosted infrastructure entails, the network drive holding the scrubjay storage can also be located on a cloud VPS.

## Feature list

**Basic.** Transcripts are indexed, can be searched, and can be pulled into context via an [MCP server](https://henba1.github.io/scrubjay/archive-mcp/index.md) running on the NAS host (the central node).

**Quality-of-life.** scrubjay catalogues sessions and keeps track of e.g. the topic, harness and token usage. To get an overview across sessions, users can print a session table and browse it manually.

**New commands.** scrubjay functions are callable in Claude Code and opencode via [`/sj*` commands](https://henba1.github.io/scrubjay/slash-commands/index.md).

**Installation.** [Onboarding](https://henba1.github.io/scrubjay/onboarding/index.md) of new nodes into the scrubjay network happens via an onboarding script. The goal is as few manual steps as possible, while keeping the user informed about what is happening.

## Advantages

scrubjay especially makes sense for a many-machine setup on which a team of developers run Claude or other SDE agents and want to improve the exchange of their session context and agent artefacts.

### Cross-harness resume, setup and exchange

Operations like session lookup, setup and retention across a distributed host network become much easier:

- Setting up Claude Code and/or opencode becomes much easier in distributed infrastructure settings, e.g. where a few locally hosted worker nodes are accessed by a pool of client nodes.
- Resume and lookup become independent of the harness: start with Claude Code, run into a token cap, continue the transcript with opencode — and vice versa. See [Session hand-off](https://henba1.github.io/scrubjay/handoff/index.md).

## Differentiation

How it differs from:

### "Just syncing everything via one git repo"

A repo is a place files sit; it is not a mechanism that applies them. Agent config lives at user scope (`~/.claude/`, `~/.config/opencode/`), not in the project tree. Somebody still symlinks or copies it per machine, and then machines drift silently. scrubjay pulls and re-applies at every session start, merges base with per-host overrides, and ships `/sjdoctor` to prove a machine is actually in sync.

Transcripts also do not belong in git: they are big, they do not diff usefully, and they may contain confidential information. This approach would not solve the inter-harness quality-of-life problems either.

### "Just directly using a NAS that each team member can access"

This induces inflexibility, as project roots need to be located on the NAS, and it introduces I/O concurrency issues if the same location is changed by two users. That can be solved with a versioning system, but we would still have to coordinate a lot of unnecessary continuous I/O where it is not actually needed: asynchronous updates are entirely fine for the intended use case. scrubjay runs everything on local disk and relays small artefacts asynchronously, which is much more maintainable and robust.

The NAS solution also makes the MCP integration unnecessarily complex, as many working trees would exist in parallel if the MCP is asked to surface a currently contested location on the drive.

### "Basic functionality surfaced by the harness (e.g. Claude Code)"

As of now, this is limited to one host and one harness. scrubjay breaks that inflexibility open.

Anthropic may of course release the functionality scrubjay implements gradually into the Claude Code harness, and opencode may pick up on it too. But it is highly doubtful that this will be peer-to-peer or privacy-by-design oriented.

## Downsides

**Setup effort (one time).** There is a higher up-front cost for setup. Setting up and onboarding new nodes in a scrubjay network should be easy, but there may still be manual work involved, and basic knowledge of networking (WireGuard, port traversal, reverse proxying, DDNS for stable hostnames, etc.) is still required. The additional up-front cost of onboarding might not make sense for a user who runs a single machine and only one harness.

scrubjay ships with an onboarding script that sets up the networking and MCP. However, setting up WireGuard tunnels (keys) and NAT traversal may require sudo rights. scrubjay will print the commands to run — but check before you sudo.

**No per-person access control.** scrubjay knows hosts, not users. Everyone pointed at the same storage sees everything in it — including the shared config and memory that ride along with the sessions. For a small, trusting team that is the point; where separation matters, the answer today is one archive per team or per engagement, not permissions inside one archive.

**Some commands take getting used to.** Ending a session with `/sjlog` (or `/clear`) gives it a written one-sentence topic. Quit any other way and the session still lands in the archive — it just gets the first prompt as its topic line, which makes it harder to recognise later when you are scanning the catalogue. This will be improved in a future update.

**The scrubjay storage on the central node is a single point of failure.** In future, the central storage should be moved to an off-premise VPS and managed via a distributed database such as Apache Cassandra, which opens up the path to further optimisation. For production environments relying on 100% uptime, this is non-negotiable. See [Archive durability](https://henba1.github.io/scrubjay/durability/index.md) for what protects the archive today.

Disclaimer

scrubjay is work in progress. It is a **source-available project** ([FSL-1.1-ALv2](https://henba1.github.io/scrubjay/licensing/index.md)), so feel free to contribute — and when using it, **treat it as alpha-stage software**. Understand the implications before copy-pasting sudo commands from the initial onboarding.

It is also recommended that you make yourself familiar with networking and security basics (WireGuard tunnels) and correctly harden the involved infrastructure (automatic security updates, firewall setup, etc.) before using scrubjay to sync across networks.
