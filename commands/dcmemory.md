---
description: dotclaude — enable/repair cross-machine memory on THIS machine (idempotent)
allowed-tools: Bash(bash:*)
---
Setting up this machine for cross-machine memory (the self-hosted NAS git repo). Idempotent —
safe to run on an already-configured machine; it ensures the config keys, the bare repo (local
backend) or the git SSH key + alias (WG client), then clones/pulls and links the memory dirs.

!`bash ~/.claude/hooks/../bin/onboard-memory.sh 2>&1`

Report whether memory is ready. If a WG-client authorize line was printed, tell me to add it to
the receiver's authorized_keys (server-side step). For a brand-new machine that isn't set up at
all yet, the full flow is `bin/onboard.sh` instead.
