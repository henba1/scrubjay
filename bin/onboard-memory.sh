#!/usr/bin/env bash
# Set up THIS machine for cross-machine memory (the self-hosted NAS git repo). Idempotent:
# run it on a fresh machine to turn memory sync on, or on an existing one to enable/repair it —
# re-running when already configured is a safe no-op.
#   - ensures DOTCLAUDE_MEMORY{,_REMOTE} in ~/.config/dotclaude/config
#   - local backend (this box has the NAS mounted): creates the bare repo on the NAS if absent
#   - WG client: generates a dedicated git SSH key + 'claude-memory' ssh alias, and prints the ONE
#     authorized_keys line to add on the receiver (server side stays manual, like the relay key)
#   - clones/pulls the memory repo, then re-points per-project memory dirs at it (via claude-sync)
# Unattended via env: MEM_BARE, MEM_GIT_USER, MEM_KEY, MEM_RECV_HOST, MEM_RECV_PORT
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; dc_load_config

info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }

CFGDIR="$HOME/.config/dotclaude"; CFG="$CFGDIR/config"; mkdir -p "$CFGDIR"; touch "$CFG"
backend="${DOTCLAUDE_TRANSCRIPT_BACKEND:-off}"
mem="$(dc_memory)"
remote="$(dc_memory_remote)"
guser=""; authorize_key=""
# comment written above the keys in the config — backend picks the custody story (NAS vs GitHub)
mem_note="its own git repo, self-hosted on the NAS (never GitHub)."

if [ -n "$remote" ]; then
  ok "memory remote already configured: $remote"
else
  case "$backend" in
    local)
      # the bare repo lives INSIDE the NAS storage folder, next to the transcript trees
      remote="${MEM_BARE:-${DOTCLAUDE_LOCAL_CHATS:-/mnt/nas1/dotclaude-storage}/memory.git}"
      info "local backend → bare repo on the NAS: $remote"
      ;;
    rsync-wg)
      # Client over WG. Git can't reuse the rrsync relay key (forced command), so make a dedicated
      # key + ssh alias 'claude-memory' to a SHELL user on the receiver that can serve the bare repo.
      gkey="${MEM_KEY:-$HOME/.ssh/claude_memory_ed25519}"
      gbare="${MEM_BARE:-/srv/claude-chats/memory.git}"   # /srv/claude-chats → the NAS storage folder
      # Memory rides the SAME connection as the transcript relay — same receiver box, same account
      # (claude-rx), same jump host. The ONLY thing that differs is the key (the receiver pins each
      # key to one forced command: rrsync for transcripts, git-shell for memory). So derive EVERY
      # connection field from the working `claude-receiver` alias — host, port, user AND ProxyJump —
      # and never hand-pick them. (Earlier bugs: defaulting user to $USER reached a nonexistent
      # account; forgetting ProxyJump aimed straight at the LAN IP and timed out.)
      recv_user="$(ssh -G claude-receiver 2>/dev/null  | awk '/^user /{print $2; exit}')"
      recv_host="$(ssh -G claude-receiver 2>/dev/null  | awk '/^hostname /{print $2; exit}')"
      recv_port="$(ssh -G claude-receiver 2>/dev/null  | awk '/^port /{print $2; exit}')"
      recv_jump="$(ssh -G claude-receiver 2>/dev/null  | awk '/^proxyjump /{print $2; exit}')"
      guser="${MEM_GIT_USER:-${recv_user:-$USER}}"
      local_host="${MEM_RECV_HOST:-$recv_host}"
      local_port="${MEM_RECV_PORT:-${recv_port:-22}}"
      jump="${MEM_RECV_JUMP:-$recv_jump}"
      [ -n "$local_host" ] || { warn "set MEM_RECV_HOST=<receiver host/IP> and re-run"; exit 1; }
      mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
      [ -f "$gkey" ] || { ssh-keygen -t ed25519 -N "" -f "$gkey" -C "$(dc_host) memory-git" >/dev/null \
                            && ok "generated memory-git key: $gkey"; }
      SSHCFG="$HOME/.ssh/config"; touch "$SSHCFG"; chmod 600 "$SSHCFG"
      if ! grep -qE '^[Hh]ost[[:space:]]+claude-memory$' "$SSHCFG"; then
        { echo; echo "Host claude-memory"; echo "    HostName $local_host"; echo "    Port $local_port"
          echo "    User $guser"; echo "    IdentityFile $gkey"; echo "    IdentitiesOnly yes"
          [ -n "$jump" ] && [ "$jump" != none ] && echo "    ProxyJump $jump"; } >> "$SSHCFG"
        ok "ssh alias 'claude-memory' → $guser@$local_host:$local_port${jump:+ via $jump}"
      fi
      remote="claude-memory:$gbare"
      authorize_key="$gkey.pub"
      ;;
    git)
      # GitHub-only path: memory rides its OWN private repo (SEPARATE from claude-chats), pushed with
      # your normal GitHub SSH credentials — NO dedicated key and NO receiver authorized_keys step
      # (unlike the NAS/WG path, so this is actually the simpler wiring). dc-bootstrap.sh creates the
      # `claude-memory` repo under YOUR account if it doesn't exist yet; override the whole thing with
      # MEM_GIT_REMOTE=git@github.com:<owner>/<repo>.git.
      #
      # ⚠ PRIVACY TRADE-OFF — the whole reason this isn't the default. Memory files carry real
      # filesystem paths, so this stores those paths in a private GitHub repo: a THIRD PARTY holds
      # them (private + encrypted at rest, but off your hardware). The self-hosted alternative
      # (local / rsync-wg) keeps memory on gear you own and never lets it reach GitHub — but you pay
      # for that in setup: a NAS box to host the bare repo, WireGuard tunnels between machines, and
      # DDNS so clients can find home. This git path trades that standing infrastructure for
      # third-party custody. Pick by how sensitive the paths in your memory actually are.
      remote="${MEM_GIT_REMOTE:-}"
      if [ -z "$remote" ]; then
        # dc-bootstrap resolves YOUR owner (DOTCLAUDE_OWNER / `gh api user`, never the upstream
        # account), creates the private repo if absent, and prints its SSH URL.
        remote="$("$APP/bin/dc-bootstrap.sh" --repo claude-memory 2>/dev/null)" || remote=""
      fi
      if [ -z "$remote" ]; then
        # bootstrap couldn't create it (no gh, or no access) — fall back to deriving the owner from
        # the chats clone's origin so we can at least name the repo the user must create.
        base="${MEM_GIT_BASE:-}"
        if [ -z "$base" ]; then
          o="$(git -C "$(dc_chats)" remote get-url origin 2>/dev/null)" || o=""
          case "$o" in https://github.com/*) o="git@github.com:${o#https://github.com/}";; esac
          [ -n "$o" ] && base="${o%/*}"
        fi
        [ -n "$base" ] && remote="$base/claude-memory.git"
      fi
      [ -n "$remote" ] || { warn "git backend: create a SEPARATE private claude-memory repo, then set MEM_GIT_REMOTE=git@github.com:<owner>/claude-memory.git and re-run"; exit 0; }
      mem_note="its own PRIVATE GitHub repo — holds real filesystem paths, so it's third-party custody (private, but off your hardware)."
      info "git backend → private GitHub memory repo: $remote"
      warn "PRIVACY: this stores your memory's real filesystem paths in a PRIVATE GitHub repo (a third party holds them)."
      warn "For zero third-party custody, self-host on a NAS instead — costs more wiring (a NAS box + WireGuard + DDNS)."
      # dc-bootstrap.sh --repo claude-memory creates it via `gh`; without gh it must already exist.
      if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
             timeout 20 git ls-remote "$remote" >/dev/null 2>&1; then
        slug="${remote#git@github.com:}"; slug="${slug%.git}"
        warn "that repo isn't reachable yet — create it, then re-run:  gh repo create $slug --private"
      fi
      ;;
    *)
      warn "backend '$backend' has no NAS path — set DOTCLAUDE_MEMORY_REMOTE manually to enable memory"
      exit 0
      ;;
  esac

  # persist the keys (idempotent: append only if absent; back up first)
  if ! grep -q DOTCLAUDE_MEMORY_REMOTE "$CFG"; then
    cp "$CFG" "$CFG.bak.$(date +%s)"
    { echo "# Cross-machine memory: $mem_note"
      echo ": \"\${DOTCLAUDE_MEMORY:=$mem}\""
      echo ": \"\${DOTCLAUDE_MEMORY_REMOTE:=$remote}\""; } >> "$CFG"
    ok "wrote memory keys to $CFG"
  fi
  export DOTCLAUDE_MEMORY="$mem" DOTCLAUDE_MEMORY_REMOTE="$remote"
fi

# local backend: create the bare repo on the NAS if it doesn't exist yet, and install a post-receive
# hook that checks the latest `main` out into a sibling `memory/` dir — a browsable copy on the NAS,
# refreshed on every push (from this box or any WG client).
if [ "$backend" = local ] && [ -n "$remote" ]; then
  if [ ! -d "$remote" ]; then
    # --shared=group: the repo is multi-writer — the NAS box pushes locally as the owner, while WG
    # clients push over SSH as the relay account (e.g. claude-rx). Group-shared perms + setgid let
    # both write. (The relay account must be in the owner's group; it already is for the relay.)
    mkdir -p "$(dirname "$remote")" && git init -q --bare --shared=group "$remote" \
      && ok "created bare repo $remote (group-shared)" || warn "could not create bare repo at $remote"
  else ok "bare repo present: $remote"; fi
  hook="$remote/hooks/post-receive"
  if [ -d "$remote" ] && [ ! -f "$hook" ]; then
    cat > "$hook" <<'HOOK'
#!/bin/sh
# Keep a browsable working copy of memory on the NAS, refreshed whenever any machine pushes.
unset GIT_DIR GIT_WORK_TREE
BARE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$(dirname "$BARE")/memory"
mkdir -p "$TARGET"
git --git-dir="$BARE" --work-tree="$TARGET" checkout -f main 2>/dev/null || true
HOOK
    chmod +x "$hook" && ok "installed post-receive hook → browsable copy at $(dirname "$remote")/memory"
  fi
fi

# clone/pull, link per-project memory dirs, publish anything migrated in (first run on the NAS box)
"$APP/bin/memory-sync.sh" pull && ok "memory pulled (clone: $mem)" || warn "memory pull failed — remote reachable?"
"$APP/bin/claude-sync.sh" >/dev/null 2>&1 && ok "claude-sync applied (memory dirs linked)" || warn "claude-sync failed"
"$APP/bin/memory-sync.sh" push >/dev/null 2>&1 || true

if [ -n "$authorize_key" ] && [ -f "$authorize_key" ]; then
  echo
  info "Final step — authorize this machine for memory-git on the receiver. Add ONE line to the"
  info "'$guser' user's ~/.ssh/authorized_keys on the receiver (restricts the key to git only):"
  echo
  printf '    command="git-shell -c \\"$SSH_ORIGINAL_COMMAND\\"",restrict %s\n' "$(cat "$authorize_key")"
  echo
  info "git-shell must be installed on the receiver; then verify here:  bin/memory-sync.sh pull"
fi
ok "cross-machine memory ready on '$(dc_host)'"
