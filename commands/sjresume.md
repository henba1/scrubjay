---
description: scrubjay — continue a session from ANOTHER machine here (hand-off), then /resume it
argument-hint: [sid8 | search terms | (nothing = pick from recent)]
allowed-tools: Bash(bash:*), mcp__sjmcp__sj_recall
---
Stage a session that was started on a **different machine** into this one, so your harness's own
resume can continue it here. The transcript, its subagents, its task list and its file history come
across; the working tree does not.

Target: **$ARGUMENTS**

1. **Work out which session.**
   - Nothing given → run `bash ~/.claude/hooks/../bin/sj-resume.sh --list` (via the app path below)
     and show the user the other machines' recent sessions. Ask which one; do not guess.
   - An 8-character handle (or a full session id) → use it directly, no search.
   - Anything else → it's a description, not an id: call `sj_recall` once with it, and take the
     `sid8` of the best hit. Show the user which session you matched before staging it.

2. **Stage it**, from the directory the project lives in *on this machine* (the user's cwd, unless
   they name another — pass it with `--into`):

   ```sh
   bash "$(cd "$(dirname "$(readlink -f ~/.claude/hooks)")" && pwd)/bin/sj-resume.sh" <sid>
   ```

   Relay the script's output. It reports which host the session came from, rewrites that host's
   absolute paths to this machine's, and warns if the git branch here differs from the one the
   session was working on — **surface that warning, don't bury it**. A hand-off onto a different
   branch means the conversation remembers files that no longer look that way.

3. **Hand back to the user.** You cannot resume the session yourself — a running session can't
   become a different one. Staging is the whole job; the harness's native resume does the rest.
   The script ends by printing the exact command to run (it differs per harness, and by whether the
   session could be imported for you). **Relay that command verbatim; do not compose one yourself.**

   If the session came from a **different harness** than the one you're running in, the script says
   so and hands the conversation over as *context* instead — a new session seeded with the old
   transcript. Pass that on honestly: the content carries over, the session id and tool history do
   not. Do not describe it as a resume.

Notes worth passing on only if they apply:
- The archive is only as fresh as the last publish. If the session is still open on the other
  machine, they should run `/sjlog` there first — otherwise the last few turns aren't in the archive
  yet.
- If the script says the relay is write-only and there's no read channel, this host needs
  `bin/onboard-mcp-client.sh` run once. That is the fix; don't improvise around it.
