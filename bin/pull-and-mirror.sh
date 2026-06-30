#!/usr/bin/env bash
# Run on the always-on mirror host (any small home server). Pull the claude-chats relay and mirror it
# into the NAS archive. Designed for cron (every 30 min). Idempotent.
#   env: CHATS_REPO      clone of claude-chats    (default ~/claude-chats)
#        CHATS_REPO_URL  git remote to clone on first run, e.g.
#                        git@github.com:<your-gh-user>/claude-chats.git  (required if not cloned)
#        NAS_DIR         destination on the NAS, e.g. /mnt/nas1/dotclaude-storage  (required)
set -euo pipefail

CHATS_REPO="${CHATS_REPO:-$HOME/claude-chats}"
NAS_DIR="${NAS_DIR:?set NAS_DIR to the NAS mount, e.g. /mnt/nas1/dotclaude-storage}"

[ -d "$CHATS_REPO/.git" ] || \
  git clone "${CHATS_REPO_URL:?set CHATS_REPO_URL to your claude-chats remote on first run}" "$CHATS_REPO"
git -C "$CHATS_REPO" pull --ff-only -q

[ -d "$NAS_DIR" ] || { echo "NAS_DIR '$NAS_DIR' not mounted — skipping" >&2; exit 0; }
# Mirror transcripts only; --delete keeps NAS == relay (canonical archive on the NAS). Exclude the
# self-hosted memory repo + its browsable checkout, which live in the same folder but are NOT part
# of the transcript relay — without these excludes, --delete would wipe them.
rsync -a --delete --exclude='.git' --exclude='README.md' --exclude='.gitignore' \
      --exclude='memory.git' --exclude='memory' \
      "$CHATS_REPO"/ "$NAS_DIR"/
echo "$(date '+%F %T') mirrored $(find "$NAS_DIR" -name '*.jsonl' | wc -l) transcripts -> $NAS_DIR"
