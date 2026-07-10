#!/usr/bin/env bash
# Receiver-side forced command for the write-only transcript relay. Wraps `rrsync -wo <root>`
# so that after each push the archive perms are normalized: the relay account (e.g. scrubjay-rx)
# writes files 0600, but the archive OWNER (the human + the MCP server) must read them via the
# shared group. setgid dirs already stamp files with the owner's group; this widens the mode to
# group-read so the group actually grants access. Client-agnostic — fixes every client that
# pushes through this key, now and in future.
#
# Why a wrapper and not a client flag: rrsync (write-only) has no `chmod` in its allowed
# options, and rsync `--no-perms` stamps the destination at the source's mode (0600) — a umask
# can only remove bits, never add group-read. So the mode must be normalized after the write
# lands, by the account that owns the files. rrsync uses subprocess.run (not exec), so control
# returns here after the push completes.
#
# Pin it in the relay account's authorized_keys (server-side; same manual step as the plain
# rrsync line it replaces), keeping the existing pubkey + `restrict`:
#
#   command="<APP>/bin/sj-receive.sh <root>",restrict <relay-pubkey>
#
# where <root> is the rrsync root (the storage dir clients push into, e.g.
# /srv/scrubjay-chats).
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"   # forced commands get a minimal PATH

root="${1:?rrsync root}"

rrsync -wo "$root"; st=$?

# Widen perms so the shared group can read what the relay just wrote. Best-effort: chmod only
# succeeds on files this account owns (others error out and are ignored); never fail the push.
# setgid on dirs keeps the owner's group flowing to files created later.
#   Resolve the root first: it may be a symlink (e.g. /srv/scrubjay-chats -> the NAS storage), and
#   `find` in its default -P mode won't descend into a symlink given as the starting point — it
#   would silently chmod nothing. realpath gives find a real directory to walk.
scan="$(realpath -e "$root" 2>/dev/null || printf '%s' "$root")"
find "$scan" -type d -exec chmod g+rxs {} + 2>/dev/null || true
find "$scan" -type f -exec chmod g+r   {} + 2>/dev/null || true

exit $st
