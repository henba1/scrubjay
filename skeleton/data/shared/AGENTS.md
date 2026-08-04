<!--
  Shared agent instructions — used by BOTH harnesses scrubjay syncs.

  scrubjay points opencode at this file by absolute path (opencode.json `instructions`), and
  symlinks it into ~/.claude/rules/ for Claude Code — user-level rules load on every session in
  every project. (Claude Code reads CLAUDE.md, *not* AGENTS.md; the rules dir is how a shared
  file reaches it without editing the CLAUDE.md you authored.) A `git pull` of the data repo
  updates it live on every machine, the same way the hooks symlink self-updates.

  Put instructions here that are true regardless of which agent you are driving. Harness- or
  machine-specific rules belong elsewhere: Claude in claude-md/CLAUDE.md, opencode defaults in
  opencode/opencode.base.json, and per-host overrides in hosts/<host>/.
-->

# Shared instructions

(Replace this with your own cross-harness guidance.)
