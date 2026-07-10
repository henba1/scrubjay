# Global Claude Code instructions

> Synced to every machine by scrubjay (symlinked to `~/.claude/CLAUDE.md`).
> Keep machine-specific details out of this file — those belong in `hosts/<machine>/env.md`.

This is a starter. Replace it with your own standing instructions.

## Git & attribution

- Don't add a `Co-Authored-By` trailer to commits or PRs.
  (Also enforced by the empty `attribution` block in `settings/settings.base.json`.)

## Working style

- If you genuinely think a different approach is better than what I asked for, say so and
  explain why — don't just defer.
- Prefer reusing existing utilities over writing new code.

## Secrets & safety

- Never read or commit credentials, `.env` files, or `*.key`.
  (Also enforced by the `permissions.deny` rules in `settings/settings.base.json`.)
