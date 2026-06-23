# dotclaude

Private repo that organizes my [Claude Code](https://claude.ai/code) configuration
across machines. Top level is keyed by **machine**, so each machine's env stays
distinct and browseable — I can read one machine's rules and have Claude re-tailor
them for another (different OS/paths). It is **not** chezmoi: chezmoi *converges*
machines onto one templated source; this keeps them divergent on purpose.

## Layout

```
hosts/<machine>/          # per-machine env (TOP LEVEL = machine names)
  claude/settings.json    #   host-specific settings OVERLAY (e.g. defaultMode)
  env.md                  #   human notes: OS, paths, envs, scheduler
  chats.index.json        #   generated registry of chats on this host (metadata only)
hosts/_template/          # skeleton copied when registering a new machine
settings/settings.base.json   # shared permissions / model / effort
claude-md/                # global instructions + custom tooling (applied to ~/.claude)
  CLAUDE.md  commands/  agents/
templates/                # reusable project-rule snippets (CLAUDE.local.md)
memory/                   # portable memory facts (path-tokenized; adapt per machine)
bin/                      # the sync scripts
```

## What this does and does NOT touch

- **Applied to `~/.claude`** by `bin/claude-sync.sh`: a merged `settings.json`
  (base + host overlay, arrays unioned) and symlinks for `CLAUDE.md`, `commands/`,
  `agents/`.
- **Pull-on-demand, not auto-applied**: `templates/` (copy into a project as
  `CLAUDE.local.md`) and `memory/` (project-coupled, paths baked in — tailor by hand).
- **Never stored here**: auth tokens (`~/.claude/.credentials.json`), app state
  (`~/.claude.json`), and chat transcripts (`~/.claude/projects/**/*.jsonl`). Chats are
  tracked as a metadata **index** only. `.gitignore` enforces this as a backstop.

## Host identity

`hostname -s` is unreliable on HPC (transient login nodes like `int6`). The stable
host name is resolved as: `--host NAME` arg → `$CLAUDE_HOST` → `~/.config/dotclaude/host`
file → `hostname -s`. `claude-register-host.sh` pins it in the file.

## Onboard a new machine

```sh
git clone git@github.com:henba1/dotclaude.git ~/code/dotclaude
cd ~/code/dotclaude
bin/claude-register-host.sh --host <name>   # scaffold + pin host + build chat index
# review hosts/<name>/env.md and claude/settings.json
bin/claude-sync.sh                          # apply into ~/.claude
git add -A && git commit -m "Register host <name>" && git push
```

Prereqs: `bash`, `jq`, `git`. No root, no extra binaries.

## Day-to-day

```sh
bin/claude-sync.sh            # re-apply after pulling config changes (idempotent)
bin/claude-index-chats.sh     # refresh this host's chats.index.json
```

## Cross-machine tailoring with Claude

Because everything is plain Markdown/JSON in one repo, from any project I can ask
Claude: *"read `hosts/snellius/` and adapt its rules for this macOS box"* — it reads
one host dir and writes another, or drafts a `templates/<x>/CLAUDE.local.md`.
