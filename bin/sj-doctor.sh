#!/usr/bin/env bash
# Verify that this machine's scrubjay is actually working — end to end, right now.
#
# Why this exists: scrubjay's subsystems are deliberately best-effort. A session must never be
# blocked because a NAS is asleep, so every hook call ends in `>/dev/null 2>&1 || true`. The cost
# of that design is that a machine can be silently degraded for weeks — relaying nothing, or
# publishing memory nowhere — while every session reports success. The breadcrumbs
# (sj_record_ship / sj_record_memory_sync) tell you about the LAST attempt; this tells you whether
# the wiring is sound BEFORE you rely on it.
#
#   usage: bin/sj-doctor.sh [--quiet] [--list] [section…]
#   exit:  0 = everything checked is healthy, 1 = at least one FAIL, 2 = bad usage
#
# With no section names it checks everything. Name one or more to check just those — the same
# positional style as tests/run.sh. That matters because the network probes are the slow part:
# when memory is the suspect there is no reason to wait on an ssh round-trip to the relay.
#
#   bin/sj-doctor.sh                 # everything
#   bin/sj-doctor.sh memory          # just cross-machine memory
#   bin/sj-doctor.sh memory relay    # the two that talk to the receiver
#
# Read-only by contract: it inspects config, git refs and reachability. It never writes to a repo,
# never pushes, never installs, never edits authorized_keys. Safe to run at any time, and safe for
# an agent to run unprompted.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

# The section list is the contract: `--list` prints it, the arg parser validates against it, and
# adding a check means adding a `doctor_<name>` function and one line here.
SECTIONS="config data memory relay harnesses sessions outcomes"
section_desc() {
  case "$1" in
    config)    printf 'host name, backend value, config file' ;;
    data)      printf 'the scrubjay-data clone: readable, reachable, nothing unpushed' ;;
    memory)    printf 'the memory clone: right remote, right branch, nothing unpublished' ;;
    relay)     printf 'the transcript relay for this backend is reachable' ;;
    harnesses) printf 'each configured harness has an adapter and a config dir' ;;
    sessions)  printf 'sessions on this disk that never reached the catalogue' ;;
    outcomes)  printf 'what the last ship / memory sync actually did' ;;
  esac
}

QUIET=0; WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --list)  for s in $SECTIONS; do printf '%-10s %s\n' "$s" "$(section_desc "$s")"; done; exit 0 ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) printf 'sj-doctor: unknown option %s (try --help)\n' "$1" >&2; exit 2 ;;
    *)
      # An unrecognised section is a usage error, not something to skip quietly — a typo must not
      # look like a clean bill of health for a check that never ran.
      case " $SECTIONS " in
        *" $1 "*) WANT="${WANT:+$WANT }$1" ;;
        *) printf 'sj-doctor: no such section '\''%s'\''. Available: %s\n' "$1" "$SECTIONS" >&2; exit 2 ;;
      esac ;;
  esac
  shift
done
[ -n "$WANT" ] || WANT="$SECTIONS"

_pass=0; _fail=0; _note=0
ok()   { _pass=$((_pass+1)); [ "$QUIET" = 1 ] || printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { _fail=$((_fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      fix: %s\n' "$2"; return 0; }
note() { _note=$((_note+1)); [ "$QUIET" = 1 ] || printf '  \033[33m-\033[0m %s\n' "$1"; }
head_() { [ "$QUIET" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }

# git reachability without hanging on a sleeping NAS or a DDNS that no longer resolves
git_reachable() {  # git_reachable <remote>
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=8' \
    sj_timeout 20 git ls-remote "$1" HEAD >/dev/null 2>&1
}

# Resolved once, up here rather than inside doctor_config: every section must stand alone, or
# `sj-doctor.sh relay` would abort on an unbound $backend under `set -u`.
backend="${SCRUBJAY_TRANSCRIPT_BACKEND:-off}"

# ── config ─────────────────────────────────────────────────────────────────────────────────────
doctor_config() {
  head_ "config"
  host="$(sj_host)"
  [ -n "$host" ] && ok "host name: $host" || bad "no host name" "set SCRUBJAY_HOST in ~/.config/scrubjay/config"
  case "$backend" in
    git|rsync-wg|local|off) ok "transcript backend: $backend" ;;
    *) bad "unknown transcript backend '$backend'" "use one of: git, rsync-wg, local, off" ;;
  esac
  [ -f "$HOME/.config/scrubjay/config" ] && ok "config file present" \
    || note "no ~/.config/scrubjay/config — running on defaults (bin/onboard.sh writes one)"
}

# ── data repo (config sync) ────────────────────────────────────────────────────────────────────
doctor_data() {
  head_ "config sync (scrubjay-data)"
  data="$(sj_data 2>/dev/null || true)"
  if [ -z "$data" ] || [ ! -d "$data" ]; then
    bad "data repo not found${data:+ at $data}" "run bin/onboard.sh"
  elif [ ! -d "$data/.git" ]; then
    note "data dir is not a git clone — config is machine-local only"
  else
    ok "data repo: $(sj_pretty_path "$data")"
    # A corrupt object store is invisible until something tries to commit; a power cut during a
    # session-end write is enough to cause it, and every later sync then fails silently.
    if sj_timeout 30 git -C "$data" rev-parse HEAD >/dev/null 2>&1; then ok "object store readable"
    else bad "data repo is corrupt (HEAD unreadable)" "re-clone it: the working tree is intact, so clone fresh and move .git across"; fi
    if r="$(git -C "$data" remote get-url origin 2>/dev/null)" && [ -n "$r" ]; then
      if git_reachable "$r"; then ok "origin reachable"
      else bad "origin unreachable: $r" "check network/SSH key, then: git -C '$data' fetch"; fi
      b="$(git -C "$data" branch --show-current 2>/dev/null)"; b="${b:-main}"
      if n="$(git -C "$data" rev-list --count "origin/$b..$b" 2>/dev/null)" && [ "${n:-0}" -gt 0 ]; then
        bad "$n local commit(s) never pushed" "git -C '$data' pull --rebase && git -C '$data' push"
      else ok "no unpushed local commits"; fi
    else note "no origin — data repo is local-only"
    fi
  fi
}

# ── cross-machine memory ───────────────────────────────────────────────────────────────────────
doctor_memory() {
  # Every check here maps to a real silent failure. Memory is the subsystem where "best-effort"
  # hurt most: it publishes from a SessionEnd hook, so nothing it says ever reaches a human.
  head_ "cross-machine memory"
  mem="$(sj_memory)"; mrem="$(sj_memory_remote)"
  if [ -z "$mrem" ]; then
    note "memory sync is off (no SCRUBJAY_MEMORY_REMOTE) — memories stay on this machine"
  elif [ ! -d "$mem/.git" ]; then
    bad "memory remote is set but there is no clone at $(sj_pretty_path "$mem")" "bin/memory-sync.sh pull"
  else
    ok "memory clone: $(sj_pretty_path "$mem")"
    cur="$(git -C "$mem" remote get-url origin 2>/dev/null || true)"
    if [ "$cur" = "$mrem" ]; then ok "origin matches the configured remote"
    else bad "origin '$cur' != configured '$mrem'" "bin/memory-sync.sh reconciles this on its next run"; fi
    b="$(git -C "$mem" branch --show-current 2>/dev/null)"; b="${b:-main}"
    # A repo on `master` against a `main` bare repo can never reconcile — pull and push both match
    # nothing, forever, without erroring in a way anyone sees.
    if [ "$b" = main ]; then ok "on branch main"
    else bad "on branch '$b', but the archive uses main" "git -C '$mem' branch -m '$b' main"; fi
    if git_reachable "$mrem"; then
      ok "memory remote reachable"
      if n="$(git -C "$mem" rev-list --count "origin/$b..$b" 2>/dev/null)" && [ "${n:-0}" -gt 0 ]; then
        bad "$n memory commit(s) never published" "bin/memory-sync.sh push"
      else ok "no unpublished memory commits"; fi
    else
      bad "memory remote unreachable: $mrem" "on a p2p backend this usually means this host's key is not yet in the receiver's authorized_keys"
    fi
  fi
}

# ── transcript relay ───────────────────────────────────────────────────────────────────────────
doctor_relay() {
  head_ "transcript relay ($backend)"
  case "$backend" in
    local)
      dest="${SCRUBJAY_LOCAL_CHATS:-}"
      if [ -z "$dest" ]; then bad "SCRUBJAY_LOCAL_CHATS unset" "point it at the mounted archive"
      elif [ ! -d "$dest" ]; then bad "archive path missing: $dest" "is the NAS mounted? see bin/sj-mount.sh"
      elif [ ! -w "$dest" ]; then bad "archive not writable: $dest" "check ownership/permissions on the mount"
      else ok "archive writable: $dest"; fi
      ;;
    rsync-wg)
      tgt="${SCRUBJAY_WG_TARGET:-}"
      if [ -z "$tgt" ]; then bad "SCRUBJAY_WG_TARGET unset" "bin/onboard.sh"
      else
        # The relay key is pinned to `rrsync -wo`, so ANY command we send is refused by design —
        # a non-zero exit is expected and proves nothing. What distinguishes reachable from not is
        # ssh's own 255: connection or authentication failure. Anything else means we got in and the
        # forced command did its job.
        sj_timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$tgt" true >/dev/null 2>&1
        if [ "$?" = 255 ]; then bad "cannot authenticate to $tgt" "add this host's relay key to the receiver's authorized_keys (a human with root on the receiver must do this)"
        else ok "receiver reachable and key accepted: $tgt"; fi
      fi
      [ -n "${SCRUBJAY_MCP_REMOTE:-}" ] && ok "read channel configured (${SCRUBJAY_MCP_REMOTE})" \
        || note "no SCRUBJAY_MCP_REMOTE — write-only host: /sjresume and archive search cannot read back (bin/onboard-mcp-client.sh)"
      ;;
    git)
      chats="$(sj_chats 2>/dev/null || true)"
      if [ -z "$chats" ] || [ ! -d "$chats/.git" ]; then bad "no chats repo at ${chats:-<unset>}" "bin/sj-bootstrap.sh"
      elif r="$(git -C "$chats" remote get-url origin 2>/dev/null)" && git_reachable "$r"; then ok "chats remote reachable"
      else bad "chats remote unreachable" "check the SSH key for GitHub"; fi
      ;;
    off) note "relay disabled — transcripts stay on this machine" ;;
  esac
}

# ── harnesses ──────────────────────────────────────────────────────────────────────────────────
doctor_harnesses() {
  head_ "harnesses"
  for h in $(sj_harnesses); do
    if [ ! -f "$APP/bin/adapters/$h.sh" ]; then bad "no adapter for '$h'" "known: $(sj_known_harnesses 2>/dev/null | tr '\n' ' ')"; continue; fi
    if sj_adapter_call "$h" sjh_present >/dev/null 2>&1; then
      cfg="$(sj_adapter_call "$h" sjh_config_dir 2>/dev/null)"
      [ -d "$cfg" ] && ok "$h: installed, config at $(sj_pretty_path "$cfg")" \
                    || note "$h: installed, but no config dir yet (bin/sync-config.sh)"
    else
      note "$h: configured to sync, but not installed on this machine"
    fi
  done
}

# ── last recorded outcomes ─────────────────────────────────────────────────────────────────────
# ── stranded sessions ──────────────────────────────────────────────────────────────────────────
# Every other section asks whether the wiring is sound. This one asks whether anything fell through
# it: a session that ended without the session-end hook firing (kill -9, closed terminal, power cut)
# is catalogued by nothing and — because the relay breadcrumb is written by the ship that never ran
# — reported by nothing either. `--dry-run` counts without writing, shipping or pushing, which is
# what keeps this section inside sj-doctor's read-only contract.
doctor_sessions() {
  head_ "sessions"
  local out n
  # The DEFAULT window, not --all: this reports the set the next SessionStart will actually fix,
  # which is what makes the advice below true. A pre-scrubjay back catalogue is not a fault, and
  # counting it here would turn a healthy machine into a wall of findings.
  out="$("$APP/bin/sj-reconcile.sh" --dry-run 2>/dev/null)" || out=""
  if [ -z "$out" ]; then
    note "could not enumerate sessions for this harness"
    return 0
  fi
  n="$(printf '%s' "$out" | sed -n 's/^sj-reconcile: \([0-9][0-9]*\) session.*/\1/p')"
  if [ -z "$n" ] || [ "$n" = 0 ]; then
    ok "every session on this disk is in the catalogue"
  else
    # Not a FAIL: the content is safe on disk and the fix is one command. It is a finding, not a
    # broken machine — and the next SessionStart will clear it on its own.
    note "$n session(s) on this disk are not in the catalogue (they ended without a clean exit)"
    printf '%s\n' "$out" | sed -n '2,6p' | sed 's/^/    /'
    note "the next session reconciles them automatically; or now: bin/sj-reconcile.sh --all"
  fi
}

doctor_outcomes() {
  # The checks above prove the wiring; these say what actually happened last time.
  head_ "last recorded outcomes"
  for pair in "ship:$(sj_ship_status_file)" "memory:$(sj_memory_status_file)"; do
    what="${pair%%:*}"; f="${pair#*:}"
    # No '^' anchor: the memory breadcrumb keeps one line per mode, so a pull failure must still
    # be seen after a push that had nothing to publish (which records `skip`, not `ok`).
    if [ ! -s "$f" ]; then note "$what: nothing recorded yet"
    elif grep -q 'result=fail' "$f" 2>/dev/null; then
      bad "$what: last attempt FAILED — $(grep 'result=fail' "$f" | tr '\n' ';')" "re-run it and re-check"
    elif grep -q 'result=skip' "$f" 2>/dev/null && ! grep -q 'result=ok' "$f" 2>/dev/null; then
      note "$what: nothing to publish yet — no run has actually reached the remote"
    else ok "$what: last attempt ok"; fi
  done
}

# ── run what was asked for ─────────────────────────────────────────────────────────────────────
for s in $WANT; do "doctor_$s"; done

# ── verdict ────────────────────────────────────────────────────────────────────────────────────
# When only some sections ran, say so in the verdict. "healthy" has to mean "everything checked
# passed", never "everything passed" — otherwise a narrow run reads as a whole-machine all-clear.
scope=""; [ "$WANT" = "$SECTIONS" ] || scope=" (checked: $WANT)"
printf '\n'
if [ "$_fail" -eq 0 ]; then
  printf '\033[32m✓ healthy\033[0m%s — %d checks passed, %d informational\n' "$scope" "$_pass" "$_note"
else
  printf '\033[31m✗ %d problem(s)\033[0m%s — %d checks passed, %d informational\n' "$_fail" "$scope" "$_pass" "$_note"
fi
[ "$_fail" -eq 0 ]
