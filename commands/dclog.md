---
description: dotclaude — publish now (memory + config + this session's transcript), like SessionEnd
allowed-tools: Bash(bash:*)
---
Running the dotclaude publish on demand — the same work the SessionEnd hook does, but without
ending the session: append the session log line, refresh the chats index, push the data repo and
the cross-machine memory repo, and relay this session's transcript/plans/history/tasks to the NAS.

!`bash ~/.claude/hooks/publish-now.sh 2>&1`

Confirm it published (note the session id) and flag anything that failed.
