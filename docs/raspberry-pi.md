# Raspberry Pi: mirror chat transcripts to the NAS

The always-on Pi is the bridge between GitHub (which remote machines can reach) and your
home NAS (which they can't). It pulls the `claude-chats` relay every 30 min and mirrors
it into `$NAS1/Claude-Code-chats`.

## One-time setup

1. SSH key on the Pi added to GitHub (read access to `claude-chats`).
2. Clone the app for the script:
   ```sh
   git clone git@github.com:henba1/dotclaude.git ~/dotclaude
   ```
3. Make sure the NAS is mounted (e.g. `/mnt/nas1/Claude-Code-chats`).
4. Test once:
   ```sh
   NAS_DIR=/mnt/nas1/Claude-Code-chats ~/dotclaude/bin/pull-and-mirror.sh
   ```

## Cron (every 30 min)

`crontab -e`:

```cron
*/30 * * * * NAS_DIR=/mnt/nas1/Claude-Code-chats CHATS_REPO=/home/pi/claude-chats /home/pi/dotclaude/bin/pull-and-mirror.sh >> /home/pi/claude-mirror.log 2>&1
```

Result: every machine's transcripts land on the NAS at
`Claude-Code-chats/<host>/<project-slug>/<session>.jsonl` within 30 min of a session
ending. The NAS copy is the canonical archive; the GitHub relay can be pruned/rotated.

## When you switch to the WireGuard transport

Once machines push peer-to-peer to the home node (see `transcript-transport.md`), the Pi
no longer pulls from GitHub — the home receiver writes straight to the NAS, and this
cron job is retired (or repurposed to rsync from the receiver to the NAS).
