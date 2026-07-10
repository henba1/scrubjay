#!/usr/bin/env bash
# Migrate a machine from the old `dotclaude` names to `scrubjay`, in place. Idempotent: safe to
# re-run; anything already migrated is skipped. Prints (does NOT perform) the root-owned and
# receiver-side steps — those need sudo and/or a different box, so they stay yours.
#
#   what it does (this machine, your user):
#     1) ~/.config/dotclaude/  ->  ~/.config/scrubjay/   (config, host, last-ship)
#     2) rewrite the config: DOTCLAUDE_* -> SCRUBJAY_*, and the dir-name tokens in the paths
#     3) rename local clone dirs: ~/.dotclaude -> ~/.scrubjay; {dotclaude-data,claude-chats,
#        claude-memory} -> scrubjay-*  and repoint each clone's git remote to the renamed repo
#     4) rename the NAS storage dir (local backend only) if its parent is writable by you
#     5) drop the stale `dcmcp` MCP registration; claude-sync re-adds `sjmcp`
#     6) re-run claude-sync to relink ~/.claude (now /sj* commands) and register sjmcp
#
#   usage:  bin/sj-migrate.sh            # dry-run: print what WOULD change
#           bin/sj-migrate.sh --apply    # do it
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
step() { printf '\033[1;36m—\033[0m %s\n' "$*"; }
run()  { if [ "$APPLY" = 1 ]; then eval "$*"; else printf '   would: %s\n' "$*"; fi; }

OLDC="$HOME/.config/dotclaude"; NEWC="$HOME/.config/scrubjay"
OLDD="$HOME/.dotclaude";        NEWD="$HOME/.scrubjay"

[ "$APPLY" = 1 ] || info "DRY RUN — showing what would change. Re-run with --apply to do it."

# 1) config dir ------------------------------------------------------------------------
if [ -d "$OLDC" ] && [ ! -d "$NEWC" ]; then
  step "config dir: $OLDC -> $NEWC"
  run "cp -a '$OLDC' '$NEWC'"
elif [ -d "$NEWC" ]; then ok "config dir already at $NEWC"
else warn "no config dir at $OLDC (nothing to migrate?)"; fi

# 2) rewrite the config (in the NEW location) ------------------------------------------
CFG="$NEWC/config"
if [ "$APPLY" = 1 ] && [ -f "$CFG" ]; then
  cp "$CFG" "$CFG.bak.$(date +%s)"
  sed -i -E \
    -e 's/DOTCLAUDE_/SCRUBJAY_/g' \
    -e 's#\.dotclaude/dotclaude-data#.scrubjay/scrubjay-data#g' \
    -e 's#\.dotclaude/claude-chats#.scrubjay/scrubjay-chats#g' \
    -e 's#\.dotclaude/claude-memory#.scrubjay/scrubjay-memory#g' \
    -e 's#\.dotclaude/dotclaude#.scrubjay/scrubjay#g' \
    -e 's/dotclaude-storage/scrubjay-storage/g' \
    "$CFG"
  ok "rewrote $CFG (DOTCLAUDE_->SCRUBJAY_, dir tokens; backup kept)"
else
  step "rewrite $CFG: DOTCLAUDE_->SCRUBJAY_ + dir-name tokens"
fi

# 3) local clone dirs + remotes --------------------------------------------------------
if [ -d "$OLDD" ] && [ ! -d "$NEWD" ]; then
  step "clone base: $OLDD -> $NEWD"; run "mv '$OLDD' '$NEWD'"
elif [ -d "$NEWD" ]; then ok "clone base already at $NEWD"; fi
declare -A RENAME=( [dotclaude-data]=scrubjay-data [claude-chats]=scrubjay-chats
                    [claude-memory]=scrubjay-memory [dotclaude]=scrubjay )
for old in "${!RENAME[@]}"; do
  new="${RENAME[$old]}"
  if [ -d "$NEWD/$old" ] && [ ! -d "$NEWD/$new" ]; then
    step "clone dir: $NEWD/$old -> $NEWD/$new"; run "mv '$NEWD/$old' '$NEWD/$new'"
  fi
  # repoint remote (GitHub redirects the old name, but keep it tidy)
  d="$NEWD/$new"
  if [ -d "$d/.git" ]; then
    url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
    case "$url" in
      *"/$old.git"|*"/$old")
        newurl="${url%$old*}$new.git"
        step "remote in $d: $url -> $newurl"; run "git -C '$d' remote set-url origin '$newurl'";;
    esac
  fi
done

# 4) NAS storage dir (local backend) ---------------------------------------------------
# Read the OLD value straight from the old config so we know the real path.
OLDSTORE="$( { [ -f "$OLDC/config" ] && . "$OLDC/config"; printf '%s' "${DOTCLAUDE_LOCAL_CHATS:-}"; } 2>/dev/null )"
if [ -n "$OLDSTORE" ] && [ -d "$OLDSTORE" ] && [[ "$OLDSTORE" == *dotclaude-storage* ]]; then
  NEWSTORE="${OLDSTORE/dotclaude-storage/scrubjay-storage}"
  parent="$(dirname "$OLDSTORE")"
  if [ -e "$NEWSTORE" ]; then ok "storage already at $NEWSTORE"
  elif [ -w "$parent" ]; then
    step "NAS storage: $OLDSTORE -> $NEWSTORE  (archive moves with the rename; inode preserved)"
    run "mv '$OLDSTORE' '$NEWSTORE'"
  else
    warn "cannot rename $OLDSTORE (no write on $parent) — do it with the account that owns it:"
    warn "    mv '$OLDSTORE' '$NEWSTORE'"
  fi
fi

# 5) drop the stale dcmcp MCP registration --------------------------------------------
if command -v claude >/dev/null 2>&1; then
  step "MCP: remove stale 'dcmcp' (sjmcp re-registers via claude-sync)"
  run "claude mcp remove dcmcp -s user 2>/dev/null || true"
fi

# If this script is running FROM a clone that step 3 just renamed, $APP now points at a path that
# no longer exists — remap it to the moved location so the final claude-sync (which relinks
# ~/.claude/{hooks,commands} and registers sjmcp) runs from the real clone, not a ghost.
if [ "$APPLY" = 1 ] && [ ! -d "$APP" ]; then
  case "$APP" in
    "$OLDD"/*) rest="${APP#"$OLDD"/}"; rest="${rest/#dotclaude/scrubjay}"; cand="$NEWD/$rest"
               if [ -d "$cand" ]; then APP="$cand"; ok "app clone moved by migration → $APP"
               else warn "app clone moved and $cand not found — run bin/claude-sync.sh by hand from the moved clone"; fi ;;
    *) warn "app path $APP vanished — run bin/claude-sync.sh by hand from the moved clone" ;;
  esac
fi

# 6) re-apply config into ~/.claude ---------------------------------------------------
step "claude-sync: relink ~/.claude (now /sj* commands) + register sjmcp"
run "'$APP/bin/claude-sync.sh' >/dev/null 2>&1 || true"

echo
if [ "$APPLY" = 1 ]; then ok "this machine migrated."; else info "dry run complete — re-run with --apply."; fi
cat <<EOF

── YOUR root / receiver steps (this script deliberately does NOT touch these) ──
On the NAS/receiver box (needs sudo), if you renamed the storage dir:
  • repoint the relay symlink:   sudo ln -sfn <new-storage-path> /srv/scrubjay-chats   (and update RECV_PATH)
  • in each remote machine's ~/.ssh/authorized_keys, the relay forced-command still names the
    old receiver script — change  bin/dc-receive.sh  ->  bin/sj-receive.sh
On every OTHER machine (snellius, hensipi, …): run  bin/sj-migrate.sh --apply  there too.
GitHub repos were renamed; existing clones keep working via GitHub's redirects, but re-run this
script on each box to point remotes + config at the new names cleanly.
EOF
