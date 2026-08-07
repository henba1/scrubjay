---
description: scrubjay — put whatever is on the clipboard into this project's assets and read it
argument-hint: "[name]"
allowed-tools: Bash(bash:*), Bash(echo:*)
---
!`bash "$(cd -P "$(dirname "$(readlink ~/.claude/hooks/sync-session.sh || echo ~/.claude/hooks/sync-session.sh)")/.." && pwd)/bin/sj-paste.sh" ${ARGUMENTS:+--name "$ARGUMENTS"} </dev/null 2>&1; echo "exit: $?"`

The last line before `exit:` is the path it wrote (everything else is status).

- **exit 0** → **Read that file now**, then carry on with whatever the user was doing. That is the
  point of the command: they pasted something so you could look at it. Say in one line what it is
  (image, PDF, text) — don't paste the path back at them, they know.
- **exit non-zero** → report the message as-is. "No clipboard here" means the session is headless or
  over SSH, and the clipboard lives on the machine they are *looking at*, not this one. Offer the
  fallback: `cat <file> | bin/sj-paste.sh -`.

Assets are machine-local and never pruned, under `$SCRUBJAY_ASSETS` (default `~/.scrubjay/assets`),
keyed by the same project slug as the archive. They do **not** sync to the other machines — if
something matters beyond this session, tell the user it needs a home in the project or the archive.
