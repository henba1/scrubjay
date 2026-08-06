---
description: scrubjay — onboard / re-configure THIS machine (guided wrapper around bin/onboard.sh)
argument-hint: "[optional, e.g. 'switch backend to rsync-wg']"
allowed-tools: Bash(bash:*), Bash(cat:*), Bash(echo:*), Bash(git:*), Read
---
Onboard or re-configure this machine with scrubjay by driving `bin/onboard.sh`.

`bin/onboard.sh` is interactive, and this command context has **no terminal** — so act as its
interactive front-end: gather the needed choices in chat, then run it unattended with those values
as env vars (its `ask`/`confirm` helpers honor a preset env var and fall back to defaults otherwise).

Current machine state:
!`echo "config:"; cat ~/.config/scrubjay/config 2>/dev/null || echo "(none)"; echo "host: $(cat ~/.config/scrubjay/host 2>/dev/null || echo unset)"`

Do this:
1. **Already configured** (config shown above): propose simply re-applying with the existing values
   (a safe conform/repair); only ask about anything the user wants to change ($ARGUMENTS).
2. **Not configured**: ask for host name; relay backend (`rsync-wg` / `local` / `git` / `off`) and its
   settings (receiver user/host/port/rrsync-path, or the NAS mount path); and whether to enable
   cross-machine memory.
3. Confirm the plan, then run it non-interactively, e.g.:
   `SCRUBJAY_HOST=<h> SCRUBJAY_BACKEND=<b> RECV_USER=<u> RECV_HOST=<…> RECV_PORT=<…> RECV_PATH=<…> LOCAL_CHATS=<…> bash ~/.claude/hooks/../bin/onboard.sh </dev/null`
4. Report what changed and surface any final **manual** step it prints (the `authorized_keys` lines
   for the receiver). Note it may also commit+push the host entry to `scrubjay-data`.

On a peer-to-peer backend, if there's no receiver yet: scrubjay sets that box up too — say so rather
than treating the NAS as a prerequisite. `bin/onboard-receiver.sh`, run **on the receiver** from a
clone there, provisions the archive root, reports per-role deps, and applies the `authorized_keys`
line via `--authorize <relay|memory|mcp> <client.pub>`. It runs unprivileged and only *prints*
whatever needs root or the router. Both are the user's to run there — never do them from here.

For a brand-new machine that doesn't have scrubjay installed yet, slash commands don't exist there —
run `bin/onboard.sh` directly in a terminal instead.
