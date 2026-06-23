# Transcript transport (pluggable)

Full chat transcripts (`~/.claude/projects/<slug>/<session>.jsonl`) are relayed off each
machine by the `SessionEnd` hook. The *how* is abstracted so the backend can change
without touching the hook.

## How it's wired

```
SessionEnd hook (hooks/log-session.sh)
   └─ bin/ship-transcript.sh <transcript> <slug> <session> <host>
         └─ hooks/transports/<backend>.sh   ::  transport_ship <src> <host/slug/session.jsonl>
```

Backend is chosen by `DOTCLAUDE_TRANSCRIPT_BACKEND` in `~/.config/dotclaude/config`.
A backend is one file defining `transport_ship <src> <relpath>`.

## Current backend: `git`  (stopgap)

Copies the transcript into the `claude-chats` private repo (`DOTCLAUDE_CHATS`) and pushes
it. A Raspberry Pi pulls and mirrors to the NAS (`raspberry-pi.md`).

⚠️ Tradeoff: transcripts transit GitHub's servers. The repo is private and treated as a
*relay* (NAS is canonical), but this is why it's a stopgap.

## Upcoming backend: `rsync-wg`  (peer-to-peer, no third party)

Planned switch: each machine holds a per-machine SSH key and rsyncs transcripts **over a
WireGuard tunnel** directly to a home login node, which writes to the NAS. No data on any
third-party server.

To switch, set in `~/.config/dotclaude/config`:

```sh
DOTCLAUDE_TRANSCRIPT_BACKEND="rsync-wg"
DOTCLAUDE_WG_TARGET="claude@home.example.net:/srv/claude-chats"   # reachable over WG
DOTCLAUDE_WG_SSHKEY="$HOME/.ssh/claude_transcripts_ed25519"
```

The stub lives in `hooks/transports/rsync-wg.sh`. Remaining work to activate:
- stand up the home receiver (restricted `rsync`-only account, append-only target);
- provision a per-machine key, authorize it on the receiver (over WG);
- retire the Pi GitHub pull (the receiver writes straight to the NAS).

Adding any other transport (e.g. S3, syncthing) is just another
`hooks/transports/<name>.sh` defining `transport_ship`.
