# Global Claude Code instructions (Hendrik)

> Personal, machine-agnostic instructions applied on every machine via
> `bin/claude-sync.sh` (symlinked to `~/.claude/CLAUDE.md`). Keep machine-specific
> details out of this file — those live in `hosts/<machine>/env.md`.

## Git & attribution
- Never add a `Co-Authored-By: Claude` trailer to commits or PRs. Only my name in
  history. (Also enforced via `attribution` in settings.)
- Branch before committing on `main`; commit/push only when I ask.
- **Always use my GitHub SSH key for pushing and signing — never the auth token
  (`GH_TOKEN`/PAT).** If a remote is `https://github.com/...`, switch it to SSH
  (`git@github.com:...`) before pushing. Commit signing uses the SSH signing key, not
  a token. The PAT is for read/API only.

## Working style
- If you genuinely think a different approach is better than what I asked for, say so
  and explain why — I may change my mind. Don't just defer.
- Prefer reusing existing utilities over writing new code.

## Secrets & safety
- Never read or commit credentials, `.env` files, or `*.key`.
