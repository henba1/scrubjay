---
description: scrubjay — sync now (pull config + cross-machine memory and apply), like SessionStart
allowed-tools: Bash(bash:*), Bash(echo:*)
---
!`bash ~/.claude/hooks/sync-session.sh --report </dev/null 2>&1; echo "exit: $?"`

The output ends with a step report: a `scrubjay sync · <n>s` header and one line per step (`✓` done,
`✗` failed, `–` skipped). Reply with that block verbatim in a ```` ```text ```` fence. Any
`scrubjay:` line above it is a warning the hook raised (a failed relay, a pending authorization):
relay it in one sentence beneath. Do not analyze otherwise.
