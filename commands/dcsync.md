---
description: dotclaude — sync now (pull config + cross-machine memory and apply), like SessionStart
allowed-tools: Bash(bash:*), Bash(echo:*)
---
Running the dotclaude sync on demand — the same work the SessionStart hook does: pull the data
repo and the cross-machine memory repo, then apply config into `~/.claude`.

!`bash ~/.claude/hooks/sync-session.sh </dev/null 2>&1; echo "dcsync exit: $?"`

Confirm config + memory are now up to date (and surface anything that failed).
