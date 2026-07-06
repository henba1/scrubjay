# Reference — useful commands

Day-to-day this all runs from hooks; reach for these when you want to do something by hand. Paths assume the default `~/.dotclaude/` layout from [Onboarding](https://henba1.github.io/dotclaude/onboarding/index.md) (if you cloned elsewhere, adjust, or run `bin/*` from inside the repo). For the in-session `/dc*` commands, see [Slash commands](https://henba1.github.io/dotclaude/slash-commands/index.md).

## Apply / refresh config now

Normally automatic at session start/end:

```
~/.dotclaude/dotclaude/bin/claude-sync.sh           # re-apply data-repo config into ~/.claude
~/.dotclaude/dotclaude/bin/claude-sync.sh --force   # also back up + replace real (non-symlink) files
~/.dotclaude/dotclaude/bin/claude-index-chats.sh    # rebuild this host's chats.index.json
```

## Pull the latest from your other machines

The SessionStart hook does both for you:

```
git -C ~/.dotclaude/dotclaude-data pull             # config, rules, memory, templates, logs
git -C ~/.dotclaude/dotclaude      pull             # the scripts & hooks themselves
```

## Find a past chat across every machine

```
git -C ~/.dotclaude/dotclaude-data pull
grep -i <keyword> ~/.dotclaude/dotclaude-data/logs/*.log
```

## Register the current machine (first-time onboarding)

```
~/.dotclaude/dotclaude/bin/claude-register-host.sh --host <name>
```

## Toggle behaviour

Set in `~/.config/dotclaude/config` (persistent) or inline before a command (one-off) — no file editing needed:

| Env var                            | Effect                                                            |
| ---------------------------------- | ----------------------------------------------------------------- |
| `DOTCLAUDE_TRANSCRIPT_BACKEND=off` | pause session shipping (other values: `local`, `rsync-wg`, `git`) |
| `DOTCLAUDE_NOSYNC=1`               | skip the start-of-session pull + sync entirely                    |
| `DOTCLAUDE_SYNC_NOPULL=1`          | sync at start but don't `git pull` first                          |
| `DOTCLAUDE_NOSHIP=1`               | end the session without shipping its transcript                   |
| `DOTCLAUDE_LOG_NOGIT=1`            | append the log line but don't commit/push it                      |

## Re-home the dotclaude clones

Move the machinery (e.g. out of `~/code` into `~/.dotclaude`):

```
mkdir -p ~/.dotclaude
mv ~/code/dotclaude ~/code/dotclaude-data ~/code/claude-chats ~/.dotclaude/

# repoint the machine-local pointer at the new location
cat > ~/.config/dotclaude/config <<'EOF'
: "${DOTCLAUDE_DATA:=$HOME/.dotclaude/dotclaude-data}"
: "${DOTCLAUDE_CHATS:=$HOME/.dotclaude/claude-chats}"
: "${DOTCLAUDE_TRANSCRIPT_BACKEND:=git}"
EOF

~/.dotclaude/dotclaude/bin/claude-sync.sh   # rebuild the ~/.claude symlinks at the new path
```

`claude-sync.sh` recomputes the app location from its own path and re-links every scope, so nothing else needs touching. Confirm with `readlink -e ~/.claude/{CLAUDE.md,commands,agents,hooks}` (no dangling links). The pinned host name in `~/.config/dotclaude/host` is unaffected. This is machine-local — nothing to commit.
