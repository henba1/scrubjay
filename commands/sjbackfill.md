---
description: scrubjay — backfill the back catalogue (sessions from before scrubjay went live) into the archive
allowed-tools: Bash(bash:*)
---
Put this machine's **back catalogue** into the archive: every session transcript already on disk,
plus the readable Markdown layer `/sjrecall` searches. The SessionEnd hook only ships sessions that
end *after* scrubjay went live, so anything older stays invisible to recall until this runs.

Idempotent — re-running ships only what changed.

1. Run this with the Bash tool:

   ```
   bash ~/.scrubjay/scrubjay/bin/sj-backfill.sh 2>&1; echo "exit: $?"
   ```

   Add `--host NAME` to file the sessions under a different host name, or `--no-push` to commit
   without publishing.

2. Report the counts it prints — how many transcripts shipped and how many readable files were
   rendered/pushed. If it warns that the readable layer was skipped, say so explicitly: transcripts
   without it are archived but **not** findable via `/sjrecall`.

Do not analyze the transcripts themselves.
