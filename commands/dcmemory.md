---
description: dotclaude — enable/repair cross-machine memory on THIS machine (idempotent)
allowed-tools: Bash(bash:*)
---
!`bash ~/.claude/hooks/../bin/onboard-memory.sh 2>&1; echo "exit: $?"`

If the output contains an `authorized_keys` line (WG client), surface it verbatim and tell me to add it
on the receiver. Otherwise reply with a single line: ✓ memory ready, or the failing line. Don't analyze.
