# Day-to-day

## Nothing to run by hand

Both housekeeping scripts run automatically via hooks, so you never update anything manually:

| When | Hook | Does |
|---|---|---|
| session **start** | `sync-session.sh` | `git pull --ff-only` **both** repos (data *and* app, so hook/script fixes propagate too), then `claude-sync.sh` — config edited on another machine arrives and applies itself. |
| session **end** | `log-session.sh` | append the log line, refresh `chats.index.json`, then `git add -A` + commit + push the **whole** data repo — `memory/`, `templates/`, host config and all. Nothing needs a manual sync. |

`git add -A` is safe because the data repo's `.gitignore` blocks secrets and transcripts
(`*.credentials*`, `*.jsonl`, `.claude.json`), so those can never be staged.

Symlinked scopes (`CLAUDE.md`, `agents/`, `hooks/`, and the per-file links in `commands/`)
go live on the pull alone — `claude-sync.sh` only has real work when `settings.json` changed
or a *new* command/agent file appeared (it relinks `commands/` from the app + data sources). You can still run
either by hand (both idempotent); the hooks just mean you don't have to:

```sh
bin/claude-sync.sh         # re-apply config (auto-runs at SessionStart)
bin/claude-index-chats.sh  # refresh this host's chats.index.json (auto-runs at SessionEnd)
```

Escape hatches (env, in `~/.config/scrubjay/config` or inline): `SCRUBJAY_NOSYNC=1`
(skip the start-of-session pull+sync), `SCRUBJAY_SYNC_NOPULL=1` (sync without pulling).
The full toggle list is in the [Reference cheatsheet](reference.md#toggle-behaviour).

## Find a past chat

Every session is logged by the `SessionEnd` hook to `scrubjay-data/logs/<host>.log`
(one line: `time | host | cwd | "first prompt" | session=id`) and pushed, so all
machines' histories are searchable from any clone of the data repo:

```sh
git -C ~/.scrubjay/scrubjay-data pull
grep -i refactor ~/.scrubjay/scrubjay-data/logs/*.log
```

The full transcript (the `.jsonl`) lives in `scrubjay-chats` / on the NAS under
`<host>/<slug>/<session>.jsonl`.

For recall by *topic* (rather than an exact word you remember typing) from inside a live
session, use the [`sjmcp` MCP server](archive-mcp.md).

## Troubleshooting

**Hooks only activate on the *next* session.** `claude-sync.sh` (and `onboard.sh`, which runs
it) install the hooks — symlinking `~/.claude/hooks` and registering them in
`~/.claude/settings.json`. But Claude reads its hooks **at session start**, so a `claude`
instance that was *already running* when you onboarded won't see them: its `SessionStart`
already fired, with no hooks to load. **Quit and reopen `claude`** after onboarding — only
sessions started afterwards run `SessionEnd` (the transcript/subagents/plans relay + log/index
push). This is the usual reason a freshly-onboarded machine "ships nothing".

- **`SessionEnd` triggers on both `/exit` and `/clear`** (the latter then starts a fresh
  session). Either way, a session that began *before* the hooks were active won't ship.
- **"SessionEnd hook … Hook cancelled":** Claude cancels hooks that haven't returned by the
  time the session process exits. `log-session.sh` detaches its network work (git push +
  relay) so shutdown can't interrupt it — just ensure the machine has pulled the app repo
  (`git -C <app-clone> pull`; `SessionStart` does this automatically next time).
- **Expecting `memory/` on the NAS?** Memory isn't relayed — it rides the `scrubjay-data`
  git sync, not the session relay (see [Transcripts: relay + NAS](transports.md)).
