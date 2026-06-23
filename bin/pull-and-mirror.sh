#!/usr/bin/env bash
# Run on the always-on box (Raspberry Pi). Pull the claude-chats relay and mirror it
# into the NAS archive. Designed for cron (every 30 min). Idempotent.
#   env: CHATS_REPO  clone of claude-chats        (default ~/claude-chats)
#        NAS_DIR     destination on the NAS, e.g. /mnt/nas1/Claude-Code-chats  (required)
set -euo pipefail

CHATS_REPO="${CHATS_REPO:-$HOME/claude-chats}"
NAS_DIR="${NAS_DIR:?set NAS_DIR to the NAS mount, e.g. /mnt/nas1/Claude-Code-chats}"

[ -d "$CHATS_REPO/.git" ] || git clone git@github.com:henba1/claude-chats.git "$CHATS_REPO"
git -C "$CHATS_REPO" pull --ff-only -q

[ -d "$NAS_DIR" ] || { echo "NAS_DIR '$NAS_DIR' not mounted — skipping" >&2; exit 0; }
# Mirror transcripts only; --delete keeps NAS == relay (canonical archive on the NAS).
rsync -a --delete --exclude='.git' --exclude='README.md' --exclude='.gitignore' \
      "$CHATS_REPO"/ "$NAS_DIR"/
echo "$(date '+%F %T') mirrored $(find "$NAS_DIR" -name '*.jsonl' | wc -l) transcripts -> $NAS_DIR"
