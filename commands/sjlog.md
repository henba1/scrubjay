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

It prints a step report — a `scrubjay publish · <sid> · <n>s` header and one line per step
(`✓` done, `✗` failed, `–` skipped, with why). Reply with that block verbatim in a ```` ```text ````
fence; it is short and it is the answer. Add one sentence only for a `✗` line, saying what it means
for this session. A `–` is not a failure (memory not configured, relay disabled). Do not analyze
otherwise.
