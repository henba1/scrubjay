---
description: scrubjay — publish now (memory + config + this session's transcript), like SessionEnd
allowed-tools: Bash(bash:*)
---
Publish this session now — the same actions as SessionEnd (memory + config push, transcript relay,
and one catalogue line for `/sjbrowse`), without ending the session.

1. Distill THIS session into **one sentence, ≤100 chars** — its *essence*: what it set out to do
   and what it achieved, phrased so a future reader scanning the catalogue instantly recalls it.
   Not the first thing that was asked — the point of the whole conversation. Plain text only: no
   double-quotes, backticks, or `$`.
2. Run this with the Bash tool, substituting your sentence for `<essence>` (keep the outer quotes):

   ```
   SCRUBJAY_TOPIC="<essence>" bash ~/.claude/hooks/publish-now.sh 2>&1; echo "exit: $?"
   ```

   `publish-now.sh` runs SessionEnd synchronously and inherits the env, so `SCRUBJAY_TOPIC` becomes
   the catalogue topic. (Skip step 1 and it falls back to the first user prompt — still valid, just
   less memorable.)

Then reply with a single line: ✓ published if the exit was 0, else the failing line. Do not analyze
the output.
