---
description: scrubjay — open the session map in a browser (start / stop / status a local viewer)
argument-hint: "[stop|status] [--port N] [--idle MIN] [--no-open]"
allowed-tools: Bash(bash:*), Bash(echo:*)
---
!`bash "$(cd -P "$(dirname "$(readlink ~/.claude/hooks/sync-session.sh || echo ~/.claude/hooks/sync-session.sh)")/.." && pwd)/bin/sj-view.sh" $ARGUMENTS </dev/null 2>&1; echo "exit: $?"`

The script above already ran. Reply with its output verbatim in a ```` ```text ```` fence, the
address included: the user opens it (it may already be open in their browser). On a non-zero exit,
say in one sentence what failed, from the output. Do not open, fetch or check the address yourself.
