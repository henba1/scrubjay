# Global Claude Code instructions (Hendrik)

> Personal, machine-agnostic instructions applied on every machine via
> `bin/claude-sync.sh` (symlinked to `~/.claude/CLAUDE.md`). Keep machine-specific
> details out of this file — those live in `hosts/<machine>/env.md`.

## Git & attribution
- Never add a `Co-Authored-By: Claude` trailer to commits or PRs. Only my name in
  history. (Also enforced via `attribution` in settings.)
- Branch before committing on `main`; commit/push only when I ask.

## Working style
- If you genuinely think a different approach is better than what I asked for, say so
  and explain why — I may change my mind. Don't just defer.
- Prefer reusing existing utilities over writing new code.

## Secrets & safety
- Never read or commit credentials, `.env` files, or `*.key`.
