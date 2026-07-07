# Mirror host (optional): also keep a NAS copy of the `git` backend

**Optional add-on for the `git` backend.** If you use GitHub as your shared store, the private
`claude-chats` repo is already a complete, permanent home for your transcripts — you don't need
this page. But if you *also* want a copy on your home NAS (extra durability, or to feed the local
MCP archive), an always-on **mirror host** (any small home server — make/model doesn't matter)
bridges the two: it pulls the `claude-chats` repo every 30 min and mirrors it into
`$NAS1/dotclaude-storage`.

## One-time setup

1. SSH key on the mirror host added to GitHub (read access to `claude-chats`).
2. Clone the app for the script:
   ```sh
   git clone git@github.com:<your-gh-user>/dotclaude.git ~/dotclaude
   ```
3. Make sure the NAS is mounted (e.g. `/mnt/nas1/dotclaude-storage`).
4. Test once (`CHATS_REPO_URL` is only needed the first run, to clone `claude-chats`):
   ```sh
   CHATS_REPO_URL=git@github.com:<your-gh-user>/claude-chats.git \
   NAS_DIR=/mnt/nas1/dotclaude-storage ~/dotclaude/bin/pull-and-mirror.sh
   ```

## Cron (every 30 min)

`crontab -e`:

```cron
*/30 * * * * NAS_DIR=/mnt/nas1/dotclaude-storage CHATS_REPO=$HOME/claude-chats $HOME/dotclaude/bin/pull-and-mirror.sh >> $HOME/claude-mirror.log 2>&1
```

Result: every machine's transcripts land on the NAS at
`dotclaude-storage/<host>/<project-slug>/<session>.jsonl` within 30 min of a session
ending. With the mirror running, the NAS copy doubles your archive; you can then prune/rotate
the GitHub repo if you like. Without it, the GitHub repo *is* your archive.

## If you later move to the WireGuard transport

If you switch machines to push peer-to-peer to the home node (see `transcript-transport.md`), the
mirror host no longer pulls from GitHub — the home receiver writes straight to the NAS, and this
cron job is retired (or repurposed to rsync from the receiver to the NAS).
