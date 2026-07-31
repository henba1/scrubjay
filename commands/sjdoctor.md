---
description: scrubjay — check THIS machine's sync is actually working (config, memory, relay, harnesses)
argument-hint: "[config|data|memory|relay|harnesses|outcomes …]  (default: all)"
allowed-tools: Bash(bash:*), Bash(echo:*)
---
!`bash "$(cd -P "$(dirname "$(readlink ~/.claude/hooks/sync-session.sh || echo ~/.claude/hooks/sync-session.sh)")/.." && pwd)/bin/sj-doctor.sh" $ARGUMENTS </dev/null 2>&1; echo "exit: $?"`

Report the result to the user:

- exit 0 → reply `✓ scrubjay healthy` plus any `-` informational lines that matter (a write-only
  host with no read channel, a harness that is configured but not installed).
- exit non-zero → list each `✗` line with its `fix:` hint, most consequential first. Do not run
  the fixes; several need a human on the receiver, and one (`authorized_keys`) must never be done
  by an agent. Offer to run the ones that are purely local.

Do not re-derive the diagnosis or re-check by hand — the script already did the work.

With no argument it checks everything. Pass section names to narrow it (`/sjdoctor memory`,
`/sjdoctor memory relay`) — worth doing when the user has already named the suspect, since the
network probes are what make a full run slow. A narrowed run says `(checked: …)` in its verdict:
report that scope, and don't present it as a clean bill of health for the whole machine.
`bin/sj-doctor.sh --list` names the sections. An unknown name exits 2 without checking anything.
