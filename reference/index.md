# Reference — useful commands

Day-to-day this all runs from hooks; reach for these when you want to do something by hand. Paths assume the default `~/.scrubjay/` layout from [Onboarding](https://henba1.github.io/scrubjay/onboarding/index.md) (if you cloned elsewhere, adjust, or run `bin/*` from inside the repo). For the in-session `/dc*` commands, see [Slash commands](https://henba1.github.io/scrubjay/slash-commands/index.md).

## Apply / refresh config now

Normally automatic at session start/end:

```
~/.scrubjay/scrubjay/bin/claude-sync.sh           # re-apply data-repo config into ~/.claude
~/.scrubjay/scrubjay/bin/claude-sync.sh --force   # also back up + replace real (non-symlink) files
~/.scrubjay/scrubjay/bin/claude-index-chats.sh    # rebuild this host's chats.index.json
```

## Pull the latest from your other machines

The SessionStart hook does both for you:

```
git -C ~/.scrubjay/scrubjay-data pull             # config, rules, memory, templates, logs
git -C ~/.scrubjay/scrubjay      pull             # the scripts & hooks themselves
```

## Find a past chat across every machine

```
git -C ~/.scrubjay/scrubjay-data pull
grep -i <keyword> ~/.scrubjay/scrubjay-data/logs/*.log
```

## Continue another machine's chat here

Stage it, then resume with Claude Code's own picker — see [handoff.md](https://henba1.github.io/scrubjay/handoff/index.md).

```
~/.scrubjay/scrubjay/bin/sj-resume.sh --list       # what's resumable, from other machines
cd <the project dir on this machine>
~/.scrubjay/scrubjay/bin/sj-resume.sh <sid8>       # stage it (rewrites the other host's paths)
claude --resume <sid>                              # …or /resume inside a session here
```

## Register the current machine (first-time onboarding)

```
~/.scrubjay/scrubjay/bin/claude-register-host.sh --host <name>
```

## Toggle behaviour

Set in `~/.config/scrubjay/config` (persistent) or inline before a command (one-off) — no file editing needed:

| Env var                           | Effect                                                            |
| --------------------------------- | ----------------------------------------------------------------- |
| `SCRUBJAY_TRANSCRIPT_BACKEND=off` | pause session shipping (other values: `local`, `rsync-wg`, `git`) |
| `SCRUBJAY_NOSYNC=1`               | skip the start-of-session pull + sync entirely                    |
| `SCRUBJAY_SYNC_NOPULL=1`          | sync at start but don't `git pull` first                          |
| `SCRUBJAY_NOSHIP=1`               | end the session without shipping its transcript                   |
| `SCRUBJAY_LOG_NOGIT=1`            | append the log line but don't commit/push it                      |

## Re-home the scrubjay clones

Move the machinery (e.g. out of `~/code` into `~/.scrubjay`):

```
mkdir -p ~/.scrubjay
mv ~/code/scrubjay ~/code/scrubjay-data ~/code/scrubjay-chats ~/.scrubjay/

# repoint the machine-local pointer at the new location
cat > ~/.config/scrubjay/config <<'EOF'
: "${SCRUBJAY_DATA:=$HOME/.scrubjay/scrubjay-data}"
: "${SCRUBJAY_CHATS:=$HOME/.scrubjay/scrubjay-chats}"
: "${SCRUBJAY_TRANSCRIPT_BACKEND:=git}"
EOF

~/.scrubjay/scrubjay/bin/claude-sync.sh   # rebuild the ~/.claude symlinks at the new path
```

`claude-sync.sh` recomputes the app location from its own path and re-links every scope, so nothing else needs touching. Confirm with `readlink -e ~/.claude/{CLAUDE.md,commands,agents,hooks}` (no dangling links). The pinned host name in `~/.config/scrubjay/host` is unaffected. This is machine-local — nothing to commit.
