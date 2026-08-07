#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The GNU-vs-BSD seam. scrubjay was written on Linux, so GNU flags leaked into it; most of them
# fail *quietly* on macOS/BSD, which is what makes them worth a test rather than a code review.
#
# These tests all pass on GNU today — that is the point. They pin the *contracts* the shims in
# bin/lib.sh promise, so a future "simplification" back to `stat -c%s` or `readlink -f` fails here
# instead of on someone's laptop three months later. Where a contract is about failing closed
# (sj_realpath) or refusing to invent a value, that is asserted explicitly.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

sj_sandbox
. "$APP/bin/lib.sh"

# ── the one that was actually broken ───────────────────────────────────────────────────────────
# bin/claude-sync.sh symlinks ~/.claude/hooks -> <app>/hooks, so every hook is invoked through a
# symlinked *parent directory*. Resolving "$(dirname "$0")/.." logically lands in ~/.claude, where
# bin/lib.sh does not exist — and since hooks are best-effort and swallow their errors, the whole
# sync would go silently dead. `cd -P` is what makes it land in the app repo instead.
section "a hook invoked through a symlinked hooks/ dir finds the app root"

fake_app="$SANDBOX/fakeapp"
mkdir -p "$fake_app/hooks" "$fake_app/bin" "$HOME/.claude"
printf 'MARKER=real-app\n' > "$fake_app/bin/lib.sh"
ln -s "$fake_app/hooks" "$HOME/.claude/hooks"

# Exactly the bootstrap line the real hooks use.
cat > "$fake_app/hooks/probe.sh" <<'EOF'
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh" || exit 1
printf '%s %s' "$APP" "$MARKER"
EOF

got="$(bash "$HOME/.claude/hooks/probe.sh" 2>&1)"
assert_eq "resolves to the app repo, not ~/.claude" "$fake_app real-app" "$got"

# And the failure mode it replaced, asserted directly so the regression is unmistakable.
cat > "$fake_app/hooks/probe-logical.sh" <<'EOF'
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
printf '%s' "$APP"
EOF
logical="$(bash "$HOME/.claude/hooks/probe-logical.sh" 2>&1)"
assert_eq "a logical cd is why this needed fixing" "$HOME/.claude" "$logical"

# ── sj_realpath: full resolution, and fail-closed ──────────────────────────────────────────────
# Two callers (sj_archive_copy, sjmcp-serve.sh confine()) use this to prove an archive entry does
# not escape its root. The archive is written by other hosts over the relay, so a symlink can sit
# inside it that never appears in the path we were handed — a shim that only canonicalized the
# parent directory would be a confinement bypass, not a portability wart.
section "sj_realpath resolves symlinks fully and refuses to guess"

mkdir -p "$SANDBOX/rp/root/sub" "$SANDBOX/rp/outside"
printf 'x\n' > "$SANDBOX/rp/outside/secret"
ln -s "$SANDBOX/rp/outside/secret" "$SANDBOX/rp/root/escape"

assert_eq "resolves a symlinked FILE to its target" \
  "$(cd -P "$SANDBOX/rp/outside" && pwd)/secret" "$(sj_realpath "$SANDBOX/rp/root/escape")"
assert_eq "resolves a real dir to itself" \
  "$(cd -P "$SANDBOX/rp/root/sub" && pwd)" "$(sj_realpath "$SANDBOX/rp/root/sub")"
check_fails "fails closed on a path that does not exist" sj_realpath "$SANDBOX/rp/nope"

# The confinement check that rides on it: an entry symlinked out of the archive is refused.
section "archive confinement still holds through the shim"
assert_eq "a symlink escaping the root is refused" "2" \
  "$(sj_archive_copy "$SANDBOX/rp/root" "escape" "$SANDBOX/rp/copied" >/dev/null 2>&1; echo $?)"
assert_no_file "and nothing was copied out" "$SANDBOX/rp/copied"

# ── stat / date / sed / timeout ────────────────────────────────────────────────────────────────
section "stat, date and sed shims report real values, not fallbacks"

printf '0123456789' > "$SANDBOX/ten"
assert_eq "sj_size returns the byte count" "10" "$(sj_size "$SANDBOX/ten")"
check_fails "sj_size fails rather than reporting 0 for a missing file" sj_size "$SANDBOX/nope"
mt="$(sj_mtime "$SANDBOX/ten")"
check "sj_mtime returns an epoch" test "${mt:-0}" -gt 0
assert_eq "sj_epoch_ymd converts epoch -> date" "1970-01-01" "$(TZ=UTC sj_epoch_ymd 0)"

# In its own directory so we can assert on the *whole* listing: the BSD spelling needs an explicit
# '' suffix argument, and getting that wrong is exactly what leaves a stray backup file next to the
# original (or, worse, consumes the following -e as the suffix and edits nothing).
mkdir -p "$SANDBOX/sedtest"
printf 'alpha\n' > "$SANDBOX/sedtest/target"
sj_sed_i -e 's/alpha/beta/' "$SANDBOX/sedtest/target"
assert_eq "sj_sed_i edits in place" "beta" "$(cat "$SANDBOX/sedtest/target")"
assert_eq "and leaves no backup file beside it" "target" \
  "$(ls "$SANDBOX/sedtest" | tr '\n' ' ' | sed 's/ $//')"

section "sj_timeout runs the command, with or without a timeout binary"
assert_eq "runs and returns output" "hi" "$(sj_timeout 5 echo hi)"
assert_eq "propagates a non-zero exit" "3" "$(sj_timeout 5 bash -c 'exit 3'; echo $?)"
# The macOS case: no timeout(1) and no gtimeout(1) on PATH. The command must still run — losing
# the guard is a far smaller harm than losing the git push it was guarding.
# Absolute paths throughout: with PATH emptied, even `bash` and `echo` are unfindable by name.
assert_eq "still runs when neither timeout nor gtimeout exists" "hi" \
  "$(PATH="$SANDBOX/emptybin" "$BASH" -c '. "'"$APP"'/bin/lib.sh"; sj_timeout 5 /bin/echo hi')"

# ── sj_ls_by_mtime ─────────────────────────────────────────────────────────────────────────────
# Replaces `find -printf '%T@ %p\n' | sort -rn`, which BSD find cannot run at all: -printf is a GNU
# extension, so on macOS the codex adapter's session lookup returned nothing, forever, in silence.
section "sj_ls_by_mtime orders newest first without find -printf"

mkdir -p "$SANDBOX/mt/nested"
for n in old mid new; do printf '%s\n' "$n" > "$SANDBOX/mt/$n.jsonl"; done
touch -t 202001010000 "$SANDBOX/mt/old.jsonl"
touch -t 202101010000 "$SANDBOX/mt/mid.jsonl"
touch -t 202201010000 "$SANDBOX/mt/new.jsonl"
printf 'x\n' > "$SANDBOX/mt/nested/deep.jsonl"
printf 'x\n' > "$SANDBOX/mt/ignore.txt"

got="$(sj_ls_by_mtime "$SANDBOX/mt" '*.jsonl' 1 | while IFS= read -r f; do basename "$f"; done | tr '\n' ' ')"
assert_eq "newest first, maxdepth honored, glob honored" "new.jsonl mid.jsonl old.jsonl " "$got"
assert_contains "without maxdepth it recurses" \
  "$(sj_ls_by_mtime "$SANDBOX/mt" '*.jsonl')" "nested/deep.jsonl"
assert_eq "a missing directory yields nothing, quietly" "" "$(sj_ls_by_mtime "$SANDBOX/nope" '*')"

# ── the shims fail closed, so `set -e` callers must guard them ─────────────────────────────────
# sj_size/sj_mtime deliberately return non-zero instead of a fabricated 0 — which means a bare
# `x="$(sj_mtime …)"` under `set -e` aborts the script. bin/claude-index-chats.sh runs under
# `set -euo pipefail` and stats a file it globbed moments earlier, so a session ending concurrently
# can genuinely make that stat fail. Losing one date is fine; losing every remaining project in the
# index is not. This pins the guarded idiom.
section "a failing stat degrades to 'unknown' instead of killing a set -e script"

cat > "$SANDBOX/seti.sh" <<EOF
set -euo pipefail
. "$APP/bin/lib.sh"
newest="/definitely/not/here.jsonl"
last_epoch=""; [ -n "\$newest" ] && last_epoch="\$(sj_mtime "\$newest" 2>/dev/null || true)"
last=unknown
[ -n "\$last_epoch" ] && last="\$(sj_epoch_ymd "\${last_epoch%.*}" 2>/dev/null || echo unknown)"
printf 'survived:%s' "\$last"
EOF
assert_eq "guarded form survives and reports unknown" "survived:unknown" "$(bash "$SANDBOX/seti.sh")"

# The unguarded form is what this replaced — asserted so the reason the guard exists is on record.
cat > "$SANDBOX/seti-bad.sh" <<EOF
set -euo pipefail
. "$APP/bin/lib.sh"
last_epoch="\$(sj_mtime "/definitely/not/here.jsonl" 2>/dev/null)"
printf 'survived'
EOF
assert_eq "unguarded form aborts — which is why the guard is there" "" "$(bash "$SANDBOX/seti-bad.sh" 2>/dev/null)"

# And the real indexer, end to end: it must produce a valid index rather than dying partway.
section "bin/claude-index-chats.sh produces a valid index"

proj="$CLAUDE_CONFIG_DIR/projects/-tmp-demo"
mkdir -p "$proj"
printf '{"type":"user","cwd":"/tmp/demo","message":{"content":"hi"}}\n' > "$proj/aaaa1111.jsonl"
out="$(bash "$APP/bin/claude-index-chats.sh" 2>&1)"; rc=$?
# Report the script's own output on failure — a bare "expected 0, got 1" would send the next
# reader hunting for a stack trace the runner already has in hand.
assert_eq "the indexer exits 0${out:+ (said: $out)}" "0" "$rc"
idx="$SCRUBJAY_DATA/hosts/testhost/chats.index.json"
assert_file "it wrote chats.index.json" "$idx"
check "the index is valid JSON" jq -e . "$idx"
assert_eq "and dated the project from its transcript" "1" \
  "$(jq -r '[.[] | select(.slug=="-tmp-demo") | select(.last|test("^[0-9]{4}-"))] | length' "$idx" 2>/dev/null)"

section "awk interval expressions {n} — unsupported by mawk, and it fails SILENTLY"
# Debian/Ubuntu ship mawk as /usr/bin/awk, and mawk has no {n} repetition: a pattern using it
# matches NOTHING and the script reports an empty result rather than an error. Cost us a
# zero-row catalogue in sj-table.sh. Spell repetition out, and keep it spelled out.
probe='| 2026-08-02 10:00 |'
assert_eq "the {4} form cannot be relied on" "" \
  "$(printf '%s\n' "$probe" | awk '/^\| [0-9]{4}-/' 2>/dev/null)"
assert_eq "the spelled-out form matches everywhere" "$probe" \
  "$(printf '%s\n' "$probe" | awk '/^\| [0-9][0-9][0-9][0-9]-/' 2>/dev/null)"
check_fails "no shipped script uses an awk {n} interval" \
  grep -rlE 'awk[^|]*\[0-9\]\{[0-9]' "$APP/bin" "$APP/hooks"

finish
