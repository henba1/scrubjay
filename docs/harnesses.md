# Harnesses

scrubjay is not Claude-only. A **harness** is the coding agent that produces and consumes
sessions — [Claude Code](https://claude.ai/code), [opencode](https://opencode.ai), or
[codex](https://github.com/openai/codex). Everything scrubjay does — sync your config in, relay
each session out, and recall it later from any machine — is defined against a small seam so a new
harness can be added without touching the archive, the `logs/` catalogue, memory, or the readable
Markdown layer that makes cross-harness recall work.

Which harnesses a machine syncs into is `SCRUBJAY_HARNESSES` in `~/.config/scrubjay/config`
(space-separated; default `claude`). [Onboarding](onboarding.md) auto-detects the agents installed
on the machine and sets this for you.

## What's supported

| | Claude Code | opencode | codex |
|---|---|---|---|
| **Relay sessions to the archive** | ✅ | ✅ | ✅ |
| **Cross-harness recall** (readable rendering) | ✅ | ✅ | ✅ |
| **Read the archive from inside** (`/sjrecall` & co.) | ✅ | ✅ | — |
| **Config sync *into* the harness** | ✅ | ✅ | — |
| **Session hand-off** (continue a session on another machine) | ✅ | ✅ | — |

"Cross-harness recall" is the payoff of the shared shape: a session started in Claude Code on your
laptop is searchable — and readable — from opencode on your desktop, and vice versa, because every
harness's renderer emits the same `# title` / `_N turns_` / `## User` · `## Assistant` Markdown.

## opencode

opencode is a first-class harness: your history relays into the archive, you can recall it from
inside opencode, and **your setup follows you there too**.

If opencode is on `PATH` when you onboard, it's detected automatically and there's nothing more to
do. To add it to a machine that's already set up:

```sh
echo ': "${SCRUBJAY_HARNESSES:=claude opencode}"' >> ~/.config/scrubjay/config
bin/sync-config.sh
```

`sync-config.sh` then writes the following into `~/.config/opencode/` — additively, and it never
rewrites a key it doesn't own (a setting you chose that the data repo never mentions always
survives, and an unparseable `opencode.json` is refused rather than clobbered):

| What | Where | From |
|---|---|---|
| shared + per-host settings | `opencode.json` (deep-merged **under** your own keys) | `opencode/opencode.base.json` + `hosts/<host>/opencode/opencode.json` |
| shared instructions | `opencode.json` → `instructions[]` | `shared/AGENTS.md` (by absolute path — live on `git pull`) |
| the lifecycle bridge | `opencode.json` → `plugin[]` | the app (sessions get logged + relayed) |
| the archive server | `opencode.json` → `mcp.sjmcp` | the app (`/sjrecall`, `/sjfind`, `/sjbrowse` work inside opencode) |
| the `/sj*` + your commands | `commands/*.md` | the app + `claude-md/commands/` (yours override on a name clash) |
| agents | `agent/*.md` | `claude-md/agents/` (translated) + `opencode/agent/` (native) |

The settings merge is the same model as Claude's `settings.base.json` + per-host overlay: shared
defaults apply, the host overlay wins where it sets a key, and every key *you* set that the data
repo doesn't mention is left untouched.

!!! note "How Claude agents become opencode agents"
    `claude-md/agents/*.md` are authored for Claude, so scrubjay translates rather than copies them:
    it drops the Claude-only `name:`/`model:` lines, adds `mode: subagent`, and maps Claude's
    `tools:` **allowlist** onto opencode's `permission` map — allowing the listed tools and
    **denying every other tool opencode knows**, so a restricted agent can't quietly gain access it
    was never granted. Native agents you write for opencode go in `opencode/agent/` and are used
    as-is (they win a name clash). Generated files are rewritten on every sync — edit the source in
    the data repo, never the copy.

Same-harness hand-off runs `opencode import` for you: `bin/sj-resume.sh <handle> --import` (the
default) stages another machine's session and imports it into opencode in the destination project,
leaving one command to run. See [Session hand-off](handoff.md).

## codex

codex **relays and is recallable today** — its sessions land in the archive with a readable
rendering, so they show up in `/sjrecall` alongside everything else. Config sync into codex, reading
the archive from inside codex, and hand-off into it are not built yet: codex keeps its config as
TOML (where scrubjay's settings story is a `jq` merge) and resolves session ids through its own
index, both of which need dedicated work. The details are tracked in
[`bin/adapters/ROADMAP.md`](https://github.com/henba1/scrubjay/blob/main/bin/adapters/ROADMAP.md).

## Adding a harness

The seam is `bin/adapters/<harness>.sh`: an adapter answers where the agent keeps its config, what a
session's records are, how it renders to the shared Markdown shape, and how a session is resumed. The
contract for implementers is [`bin/adapters/README.md`](https://github.com/henba1/scrubjay/blob/main/bin/adapters/README.md);
`claude.sh` is the reference implementation.
