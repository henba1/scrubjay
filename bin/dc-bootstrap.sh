#!/usr/bin/env bash
# Create + seed the PRIVATE sibling repos this machine needs, under YOUR GitHub account.
#
# dotclaude (the app) is public and you run it straight from upstream — no fork required. Your
# actual content lives in separate PRIVATE repos under your own account:
#
#   dotclaude-data   instructions, settings, per-host notes, the log catalogue   (always required)
#   claude-chats     full transcripts, for the `git` relay backend               (git backend only)
#   claude-memory    cross-machine memory, for the `git` backend                 (opt-in; onboard-memory.sh)
#
# This is the step that used to be missing: a fresh user had no dotclaude-data, so onboard.sh died
# on `clone failed`. Existence is probed over SSH (`git ls-remote`), so only *creating* a repo needs
# the `gh` CLI — without it we print the exact command and stop.
#
# Idempotent: existing repos are left alone, and a data repo that already has settings/ is not reseeded.
#
# usage: dc-bootstrap.sh                # ensure dotclaude-data (+ claude-chats on the git backend)
#        dc-bootstrap.sh --repo NAME    # ensure ONE private repo exists remotely; print its SSH URL
#
# Env: DOTCLAUDE_OWNER    GitHub account owning your private repos (default: `gh api user`)
#      BASE               where sibling clones live (default: parent of the app clone)
#      DOTCLAUDE_BACKEND  rsync-wg|local|git|off — decides whether claude-chats is needed
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"

info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# This project's upstream. Your private data must NEVER be assumed to live here — cloning the
# public app repo would otherwise make onboard.sh reach for the maintainer's private repos.
UPSTREAM_OWNER="henba1"

gh_login()  { have gh && gh api user --jq .login 2>/dev/null; }
ssh_url()   { printf 'git@github.com:%s.git' "$1"; }                       # ssh_url <owner/name>
# Exists AND our key can read it. BatchMode/no-prompt so a missing key fails fast instead of
# hanging on an interactive passphrase or credential prompt.
remote_has() {
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' \
    timeout 20 git ls-remote "$(ssh_url "$1")" >/dev/null 2>&1
}

# ---- resolve the owner of YOUR private repos ------------------------------------------
# Deliberately independent of the app clone's origin: the app may come from upstream while your
# content lives under your own account. That decoupling is why no fork is needed.
resolve_owner() {
  local o="${DOTCLAUDE_OWNER:-}" gl
  [ -n "$o" ] || o="$(gh_login)"
  if [ -z "$o" ]; then   # last resort: the app clone's origin owner
    o="$(git -C "$APP" remote get-url origin 2>/dev/null)" || o=""
    o="${o%.git}"; o="${o%/*}"; o="${o##*[:/]}"
  fi
  [ -n "$o" ] || die "can't determine your GitHub account — set DOTCLAUDE_OWNER=<your-gh-user>"

  # Refuse to treat the upstream account as yours. Without this, a user who clones the public app
  # repo and has no `gh` would silently try to clone/create henba1/dotclaude-data.
  if [ "$o" = "$UPSTREAM_OWNER" ]; then
    gl="$(gh_login)"
    if [ "$gl" != "$UPSTREAM_OWNER" ]; then
      warn "owner resolved to '$UPSTREAM_OWNER' — that's this project's UPSTREAM account, not yours."
      warn "You don't need to fork dotclaude; you need your own private data repos."
      die  "set DOTCLAUDE_OWNER=<your-gh-user> and re-run${gl:+ (gh says you are '$gl')}"
    fi
  fi
  printf '%s' "$o"
}

# ---- ensure a private repo exists remotely --------------------------------------------
ensure_repo() {  # ensure_repo <owner/name> <description>
  local full="$1" desc="$2"
  if remote_has "$full"; then ok "repo exists: $full"; return 0; fi
  if have gh; then
    info "creating private repo $full"
    if gh repo create "$full" --private --description "$desc" >/dev/null 2>&1; then
      ok "created $full (private)"; return 0
    fi
    warn "gh repo create failed for $full (already exists but unreadable? wrong account?)"; return 1
  fi
  warn "private repo $full does not exist (or your SSH key can't read it), and the 'gh' CLI isn't installed."
  echo "    Create it, then re-run this script:"
  echo "      gh repo create $full --private --description \"$desc\""
  echo "    …or via the web UI:  https://github.com/new   (name: ${full#*/}, visibility: Private)"
  return 1
}

ensure_clone() {  # ensure_clone <owner/name> <dir> <label>
  local full="$1" dir="$2" label="$3"
  if [ -d "$dir/.git" ]; then ok "$label already cloned ($dir)"; return 0; fi
  info "cloning $label → $dir"
  git clone -q "$(ssh_url "$full")" "$dir" 2>/dev/null || { warn "clone failed: $full"; return 1; }
  # A freshly-created repo has no commits; make sure we're on `main` before the first commit lands.
  git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1 || git -C "$dir" checkout -qB main 2>/dev/null
  ok "cloned $label"
}

# Seed a brand-new dotclaude-data. claude-sync.sh REQUIRES settings/settings.base.json (it feeds it
# to `jq --argjson` under `set -e`), and that file is where the SessionStart/SessionEnd hooks are
# registered — an empty repo would leave the whole machine inert. So seed, commit, push.
seed_data() {  # seed_data <dir>
  local dir="$1"
  if [ -f "$dir/settings/settings.base.json" ]; then ok "dotclaude-data already seeded"; return 0; fi
  info "seeding dotclaude-data from skeleton/data (settings + hooks, claude-md, host/log dirs)"
  cp -r "$APP/skeleton/data/." "$dir/" || { warn "copy of skeleton/data failed"; return 1; }
  if ( cd "$dir" && git add -A \
         && git commit -q -m "seed dotclaude-data (settings + hooks, claude-md, host/log dirs)" \
         && git push -qu origin HEAD ); then
    ok "seeded + pushed dotclaude-data"
  else
    warn "seeded locally, but the commit/push failed — push $dir by hand"
  fi
}

# claude-chats holds .jsonl transcripts, so its .gitignore must NOT block them (unlike the app/data
# repos). Seed only a README so the default branch exists for the relay's first push.
seed_chats() {  # seed_chats <dir>
  local dir="$1"
  git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1 && { ok "claude-chats already has commits"; return 0; }
  info "seeding claude-chats (README + credential guard; transcripts are NOT ignored)"
  printf '%s\n' '# claude-chats' '' \
    'Private transcript archive, relayed here by [dotclaude](https://github.com/henba1/dotclaude).' '' \
    'Keep this repo **private** — it holds full chat transcripts.' > "$dir/README.md"
  printf '%s\n' '*.credentials*' '.credentials.json' '.claude.json' > "$dir/.gitignore"
  if ( cd "$dir" && git add -A && git commit -q -m "seed claude-chats" && git push -qu origin HEAD ); then
    ok "seeded + pushed claude-chats"
  else
    warn "seeded locally, but the push failed — push $dir by hand"
  fi
}

# ---- --repo mode: ensure ONE repo, print its URL (used by onboard-memory.sh) -----------
if [ "${1:-}" = "--repo" ]; then
  [ -n "${2:-}" ] || die "usage: dc-bootstrap.sh --repo <name>"
  OWNER="$(resolve_owner)" || exit 1
  ensure_repo "$OWNER/$2" "dotclaude: private $2" >&2 || exit 1
  ssh_url "$OWNER/$2"; echo
  exit 0
fi
case "${1:-}" in
  -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0;;
  -v|--version) echo "dotclaude $(dc_version)"; exit 0;;
esac

# ---- normal mode -----------------------------------------------------------------------
dc_load_config
OWNER="$(resolve_owner)" || exit 1
BACKEND="${DOTCLAUDE_BACKEND:-${DOTCLAUDE_TRANSCRIPT_BACKEND:-git}}"
BASE="${BASE:-$(dirname "$APP")}"
mkdir -p "$BASE"

echo; info "bootstrapping private repos for '$OWNER'  (backend: $BACKEND, base: $BASE)"

rc=0
ensure_repo  "$OWNER/dotclaude-data" "dotclaude: private Claude Code config (instructions, settings, hosts)" \
  && ensure_clone "$OWNER/dotclaude-data" "$BASE/dotclaude-data" "dotclaude-data" \
  && seed_data "$BASE/dotclaude-data" || rc=1

if [ "$BACKEND" = git ]; then
  ensure_repo  "$OWNER/claude-chats" "dotclaude: private Claude Code transcript archive" \
    && ensure_clone "$OWNER/claude-chats" "$BASE/claude-chats" "claude-chats" \
    && seed_chats "$BASE/claude-chats" || rc=1
fi

echo
if [ "$rc" = 0 ]; then
  ok "private repos ready under '$OWNER'"
  info "cross-machine memory gets its own repo — enabled separately by bin/onboard-memory.sh (/dcmemory)"
else
  warn "bootstrap incomplete — create the repo(s) above, then re-run: bin/dc-bootstrap.sh"
fi
exit "$rc"
