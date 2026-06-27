---
description: dotclaude — publish now (memory + config + this session's transcript), like SessionEnd
allowed-tools: Bash(bash:*)
---
!`bash ~/.claude/hooks/publish-now.sh 2>&1; echo "exit: $?"`

Reply with a single line: ✓ published if exit was 0, else the failing line. Do not analyze the output.
