#!/usr/bin/env bash
# Test helpers. Source this at the top of every tests/test_*.sh.
#
# The one rule: a test must be HERMETIC. It may not read the developer's ~/.config/scrubjay/config,
# write to their ~/.claude, or touch their NAS — a test run on a maintainer's laptop has to do
# exactly what it does on a fresh CI runner. sj_sandbox() gets you there by moving $HOME into a temp
# dir, so every default path in bin/lib.sh (~/.config/scrubjay, ~/.claude, the memory clone) lands
# inside the sandbox and nothing outside it can be found, let alone modified.
#
# No dependencies beyond bash, jq and coreutils. No network. No `claude`/`opencode`/`codex` binary:
# a test that genuinely needs one calls need_cmd, which SKIPS rather than fails.

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export APP
FIXTURES="$APP/tests/fixtures"
export FIXTURES

_pass=0; _fail=0; _skip=0
_current=""

# ── the sandbox ────────────────────────────────────────────────────────────────────────────────
# Everything a scrubjay script reaches for, redirected into a temp dir:
#   HOME              -> no real ~/.config/scrubjay/config is ever sourced (this is the big one)
#   SCRUBJAY_DATA     -> a seeded data repo (skeleton/data + a host dir), no git
#   SCRUBJAY_*        -> the `local` transport, writing into $SANDBOX/archive
# Returns with $SANDBOX set. Cleaned up by the trap in run.sh.
sj_sandbox() {
  SANDBOX="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
  export SANDBOX

  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"

  export SCRUBJAY_DATA="$SANDBOX/data"
  cp -a "$APP/skeleton/data" "$SCRUBJAY_DATA"
  mkdir -p "$SCRUBJAY_DATA/logs" "$SCRUBJAY_DATA/hosts/testhost/claude"

  export SCRUBJAY_LOCAL_CHATS="$SANDBOX/archive"
  mkdir -p "$SCRUBJAY_LOCAL_CHATS"

  export SCRUBJAY_TRANSCRIPT_BACKEND=local
  export SCRUBJAY_HOST=testhost
  export CLAUDE_HOST=testhost
  export SCRUBJAY_LOG_NOGIT=1          # never git-commit from a test
  export SCRUBJAY_MEMORY="$SANDBOX/memory"
  export SCRUBJAY_MEMORY_REMOTE=""     # never clone/push a memory repo from a test
  export CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude"
  export OPENCODE_CONFIG_DIR="$SANDBOX/home/.config/opencode"
  export CODEX_HOME="$SANDBOX/home/.codex"
}

# ── assertions ─────────────────────────────────────────────────────────────────────────────────
# Each prints one line: what was checked, and (on failure) expected vs actual. A test file is a
# list of these; run.sh tallies them.

_ok()   { _pass=$((_pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
_no()   { _fail=$((_fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; shift; printf '      %s\n' "$@"; }

check() {  # check <name> <command...>   — passes when the command exits 0
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then _ok "$name"; else _no "$name" "command failed: $*"; fi
}

check_fails() {  # check_fails <name> <command...>  — passes when the command exits NON-zero
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then _no "$name" "expected failure, but the command succeeded: $*"
  else _ok "$name"; fi
}

assert_eq() {  # assert_eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then _ok "$1"; else _no "$1" "expected: '$2'" "actual:   '$3'"; fi
}

assert_contains() {  # assert_contains <name> <haystack> <needle>
  case "$2" in
    *"$3"*) _ok "$1" ;;
    *)      _no "$1" "expected to contain: '$3'" "actual: '$(printf '%.200s' "$2")'" ;;
  esac
}

assert_file() {  # assert_file <name> <path>
  if [ -f "$2" ]; then _ok "$1"; else _no "$1" "no such file: $2"; fi
}

assert_no_file() {  # assert_no_file <name> <path>
  if [ -e "$2" ]; then _no "$1" "file exists but should not: $2"; else _ok "$1"; fi
}

skip() {  # skip <name> <reason>
  _skip=$((_skip + 1)); printf '  \033[33m-\033[0m %s \033[33m(skipped: %s)\033[0m\n' "$1" "$2"
}

# A test that genuinely needs a harness binary skips without it — CI has none, and a contributor
# should not have to install three coding agents to run the suite.
need_cmd() {  # need_cmd <cmd> <test-name>  — returns 1 (and skips) when absent
  command -v "$1" >/dev/null 2>&1 && return 0
  skip "$2" "$1 not installed"
  return 1
}

# ── reporting ──────────────────────────────────────────────────────────────────────────────────
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# run.sh reads these back out of the subshell via the exit code + this summary line.
finish() {
  printf '__RESULT__ %d %d %d\n' "$_pass" "$_fail" "$_skip"
  [ "$_fail" -eq 0 ]
}
