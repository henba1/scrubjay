# Day-to-day

## Nothing to run by hand

Both housekeeping scripts run automatically via hooks, so you never update anything manually:

| When | Hook | Does |
|---|---|---|
| session **start** | `sync-session.sh` | `git pull --ff-only` **both** repos (data *and* app, so hook/script fixes propagate too), then `claude-sync.sh` — config edited on another machine arrives and applies itself. |
| every **turn** | `log-session.sh` | relay the transcript so far and push memory; the first turn also writes the log line and pushes the data repo. A crashed or killed session is archived up to its last finished turn. |
| session **end** | `log-session.sh` | append (or refresh) the log line, refresh `chats.index.json`, then `git add -A` + commit + push the **whole** data repo — `memory/`, `templates/`, host config and all. Nothing needs a manual sync. |

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
(one line: `time | host | cwd | "topic" | session=id | harness=… | model=… | turns=… | size=…`)
and pushed, so all machines' histories are searchable from any clone of the data repo. The
`topic` is a short title Haiku writes from the session's prompts (`claude -p`, bounded, only when
there are prompts it has not titled yet — `prompts=<n>` records how many). The same call writes
`summary=`, a sentence or two on what was done and where it was left, from the prompts and the
agent's last reply. Without it (offline, no `claude`, `SCRUBJAY_AI_TOPIC=0`) the topic is the first
real prompt, or the slash command the session ran if you typed nothing, and there is no summary. A
`/sjlog` essence wins over both, and keeps the summary an earlier row had. A session that continued
one from another machine, or carried one over from another agent, says so: `resumed_from=<host>:<sid>`. When a resumed session's topic
changes, a new line is appended and the last one per session counts. The trailing `key=value`
fields are additive, so older lines simply have fewer:

```sh
git -C ~/.scrubjay/scrubjay-data pull
grep -i refactor ~/.scrubjay/scrubjay-data/logs/*.log
```

The full transcript (the `.jsonl`) lives in `scrubjay-chats` / on the NAS under
`<host>/<slug>/<session>.jsonl`.

Rows logged before the fallback could read them show a blank topic. `bin/sj-topics.sh` fills
those in from the archived transcripts (`--dry-run` first; `--all-hosts` on the archive box,
which is usually the only machine that can read every host's sessions). It appends a corrected
row rather than editing the original, because `logs/*.log` are append-only by design — every
reader takes the newest row for a session id.

For recall by *topic* (rather than an exact word you remember typing) from inside a live
session, use the [`sjmcp` MCP server](archive-mcp.md).

## Notifications

`SCRUBJAY_NOTIFY=on` in `~/.config/scrubjay/config` rings your terminal's bell when an agent finishes
a turn or stops at a permission prompt. Claude Code, opencode and codex all ring it. It costs no
tokens: a hook writes one byte to the agent's terminal.

The bell goes to the agent's terminal rather than a sound device, so over SSH it rings on the
machine you're sitting at. tmux passes it on by default. Your terminal emulator decides what a
bell sounds like, so turn on its audible bell. A headless run (`claude -p`, `opencode run`) has no
terminal and rings nothing.

**Check the whole path** from the machine the agent runs on, over SSH and inside tmux if that's how
you work:

```sh
bash ~/.claude/hooks/../bin/sj-notify.sh test
```

### The sound

scrubjay ships a soft wooden bell, [`sounds/wood.wav`](https://github.com/henba1/scrubjay/blob/main/sounds/wood.wav)
(two marimba strikes; `sounds/make-wood.py` is its source). Download it on the computer you sit at:

```powershell
# Windows
Invoke-WebRequest https://raw.githubusercontent.com/henba1/scrubjay/main/sounds/wood.wav -OutFile "$env:USERPROFILE\Music\scrubjay-wood.wav"
```

```sh
# macOS, Linux
curl -fLo ~/.local/share/scrubjay-wood.wav https://raw.githubusercontent.com/henba1/scrubjay/main/sounds/wood.wav
```

Then point your terminal at it:

| Terminal | Setting |
|---|---|
| Windows Terminal | in `settings.json` under `profiles.defaults`: `"bellStyle": ["audible", "taskbar"]`, `"bellSound": "C:\\Users\\<you>\\Music\\scrubjay-wood.wav"` |
| kitty | `bell_path ~/.local/share/scrubjay-wood.wav` (and `enable_audio_bell yes`, the default) |
| Ghostty | `bell-features = audio` and `bell-audio-path = ~/.local/share/scrubjay-wood.wav` (1.2 on Linux, 1.3 on macOS) |
| iTerm2, WezTerm | no custom sound: they play the system alert sound. iTerm2: untick *Silence bell* (Profiles → Terminal); WezTerm: `audible_bell = "SystemBeep"`, the default |

Windows Terminal: if the bell is silent without `bellSound`, Windows' own sound for it is set to none,
which a sound file sidesteps. It keeps the file open while it runs, so save a new version under a
new name.

**nvim's `:terminal`** swallows the bell under its default `belloff=all`. Anything that leaves out
`term` lets it through:

```lua
vim.opt.belloff = { "backspace", "cursor", "complete", "copy", "ctrlg", "error", "esc", "ex", "hangul",
  "insertmode", "lang", "mess", "showmatch", "operator", "register", "shell", "spell", "wildmode" }
```

Leave Claude Code's own `preferredNotifChannel` unset: it alerts only after you've been away for
a while (about 60 s after a turn), and with both on you'd get a second bell later.

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
