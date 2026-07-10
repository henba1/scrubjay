# dotclaude-data

Your **private** companion repo to [dotclaude](https://github.com/henba1/dotclaude) — the app that
syncs it. This repo holds your actual Claude Code content; the app repo holds only machinery.

**Keep this repo private.** It carries your standing instructions, per-machine notes, and settings.

## Layout

| Path | What |
|---|---|
| `claude-md/CLAUDE.md` | your global instructions → symlinked to `~/.claude/CLAUDE.md` |
| `claude-md/agents/` | custom sub-agents → `~/.claude/agents` |
| `claude-md/commands/` | your own slash commands (merged with the app's `/dc*` set) |
| `settings/settings.base.json` | shared settings, merged with the per-host overlay |
| `hosts/<host>/env.md` | machine-specific notes (paths, quirks) |
| `hosts/<host>/claude/settings.json` | per-host settings overlay |
| `logs/<host>.log` | the session catalogue the archive MCP server reads |
| `templates/` | your own scaffolding |

`bin/claude-sync.sh` merges `settings/settings.base.json` with `hosts/<host>/claude/settings.json`
into `~/.claude/settings.json` (arrays are unioned, so a host can only *add* permissions).

## Don't remove

- The `hooks` block in `settings/settings.base.json` — it registers dotclaude's `SessionStart`
  and `SessionEnd` hooks. Without it, nothing syncs and no transcript is ever relayed.
- `settings/settings.base.json` itself — `claude-sync.sh` requires it.
