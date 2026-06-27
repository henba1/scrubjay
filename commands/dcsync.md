---
description: dotclaude — sync now (pull config + cross-machine memory and apply), like SessionStart
allowed-tools: Bash(bash:*), Bash(echo:*)
---
!`bash ~/.claude/hooks/sync-session.sh </dev/null 2>&1; echo "exit: $?"`

Reply with a single line: ✓ synced if exit was 0, else the failing line. Do not analyze the output.
