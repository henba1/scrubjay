#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# `claude resume <sid>` from a terminal (bin/sj-shell.sh → bin/sj-claude-resume.sh → bin/sj-resume.sh).
# What must hold: every other `claude` invocation reaches the binary untouched; a session from another
# machine lands where `claude --resume` looks for it, and the real binary is then run on the FULL id;
# an ambiguous prefix stops; an existing local transcript is never replaced by a different one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

ARCHIVE="$SCRUBJAY_LOCAL_CHATS"
SID=11111111-2222-4333-8444-555555555555
export SCRUBJAY_RUN_DIR="$SANDBOX/run"

# Another machine shipped this session, and the catalogue (which rides git) knows it.
mkdir -p "$ARCHIVE/otherhost/-home-user-widget-api"
cp "$FIXTURES/claude-session.jsonl" "$ARCHIVE/otherhost/-home-user-widget-api/$SID.jsonl"
printf '%s\n' "2026-10-01 10:00 | otherhost | /home/user/widget-api | \"retry backoff\" | session=$SID | harness=claude" \
  > "$SCRUBJAY_DATA/logs/otherhost.log"

# The shell function reaches the app through ~/.claude/hooks, as claude-sync.sh links it.
mkdir -p "$CLAUDE_CONFIG_DIR"; ln -s "$APP/hooks" "$CLAUDE_CONFIG_DIR/hooks"

# A stub `claude` that records where it ran and with what — never a real session.
mkdir -p "$SANDBOX/stubbin"
cat > "$SANDBOX/stubbin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$SANDBOX/claude.calls"
EOF
chmod +x "$SANDBOX/stubbin/claude"
export PATH="$SANDBOX/stubbin:$PATH"

# run_sh <shell> <dir> <args…> — the user's interactive `claude …`, with the integration sourced
run_sh() {
  local sh="$1" dir="$2"; shift 2
  : > "$SANDBOX/claude.calls"
  ( cd "$dir" && "$sh" -c '. "$0"; claude "$@"' "$APP/bin/sj-shell.sh" "$@" ) 2>&1
}
calls() { cat "$SANDBOX/claude.calls"; }

work="$SANDBOX/work"; other="$SANDBOX/elsewhere"; mkdir -p "$work" "$other"
work_real="$(cd -P "$work" && pwd)"

section "everything that is not a resume-by-id reaches the binary untouched"
run_sh bash "$work" --version >/dev/null;            assert_eq "a plain flag"            "$work_real|--version" "$(calls)"
run_sh bash "$work" -p "resume the build" >/dev/null; assert_eq "'resume' inside a prompt" "$work_real|-p resume the build" "$(calls)"
run_sh bash "$work" --resume >/dev/null;             assert_eq "--resume alone (the picker)" "$work_real|--resume" "$(calls)"
run_sh bash "$work" -r retry backoff >/dev/null;     assert_eq "--resume <search words>" "$work_real|-r retry backoff" "$(calls)"
run_sh bash "$work" resume >/dev/null;               assert_eq "bare 'resume' is a prompt" "$work_real|resume" "$(calls)"
run_sh bash "$work" resume cafe >/dev/null;          assert_eq "a short hex word is not an id" "$work_real|resume cafe" "$(calls)"
assert_no_file "and nothing was staged" "$CLAUDE_CONFIG_DIR/projects"

section "claude resume <sid8>: a session from another machine is staged here, then resumed"
out="$(run_sh bash "$work" resume 11111111 --model opus)"
assert_contains "says where it came from" "$out" "recorded on 'otherhost' in /home/user/widget-api"
assert_eq "the real binary runs on the FULL id, in this folder, keeping the other args" \
  "$work_real|--resume $SID --model opus" "$(calls)"
staged="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$work_real" | sed 's/[^A-Za-z0-9-]/-/g')/$SID.jsonl"
assert_file "staged as projects/<slug of this folder>/<sid>.jsonl — where claude --resume looks" "$staged"
assert_contains "the other host's paths now point here" "$(cat "$staged")" "$work_real"
assert_eq "the transcript was not mangled" "6" "$(jq -c . "$staged" | wc -l | tr -d ' ')"

section "already on this machine: resumed as-is, nothing fetched"
printf '{"marker":"local turn"}\n' >> "$staged"; before="$(cat "$staged")"
out="$(run_sh bash "$work" --resume 11111111)"
assert_eq "resumed directly" "$work_real|--resume $SID" "$(calls)"
assert_eq "the local transcript is untouched" "$before" "$(cat "$staged")"
out="$(run_sh bash "$other" -r 11111111)"
assert_eq "from another folder, it runs in the session's own folder" "$work_real|--resume $SID" "$(calls)"
assert_contains "and says so" "$out" "resuming it there"
out="$(run_sh bash "$work" --resume="$SID" -p hi)"
assert_eq "--resume=<full id> works too" "$work_real|--resume $SID -p hi" "$(calls)"

section "an existing local transcript is never replaced by a different one"
# SHORTER than the archive's, so without --no-clobber sj-resume.sh would back it up and replace it.
head -1 "$staged" > "$staged.tmp" && mv "$staged.tmp" "$staged"; before="$(cat "$staged")"
out="$(bash "$APP/bin/sj-resume.sh" "$SID" --into "$work" --no-clobber 2>&1)"; rc=$?
assert_eq "sj-resume.sh --no-clobber refuses" "1" "$rc"
assert_contains "and names the local copy" "$out" "already exists at $staged"
assert_eq "the local copy is untouched" "$before" "$(cat "$staged")"
assert_no_file "and not even backed up-and-replaced" "$staged.bak"

section "an ambiguous prefix lists the sessions and stops"
for s in 22222222-aaaa-4333-8444-555555555555 22222222-bbbb-4333-8444-555555555555; do
  printf '%s\n' "2026-10-02 10:00 | otherhost | /home/user/x | \"twin $s\" | session=$s | harness=claude" >> "$SCRUBJAY_DATA/logs/otherhost.log"
done
out="$(run_sh bash "$work" resume 22222222)"
assert_contains "names the first" "$out" "22222222-aaaa"
assert_contains "names the second" "$out" "22222222-bbbb"
assert_eq "and does not start claude" "" "$(calls)"

section "an unknown id fails without starting claude"
out="$(run_sh bash "$work" resume deadbeef)"
assert_contains "says so" "$out" "no archived session matches"
assert_eq "claude not started" "" "$(calls)"

section "zsh: the same function"
if need_cmd zsh "zsh sources the integration"; then
  rm -f "$staged"
  out="$(run_sh zsh "$other" resume 11111111)"
  other_real="$(cd -P "$other" && pwd)"
  assert_eq "zsh: staged and resumed in this folder" "$other_real|--resume $SID" "$(calls)"
  run_sh zsh "$work" -r >/dev/null; assert_eq "zsh: -r alone passes through" "$work_real|-r" "$(calls)"
fi

section "sj-shell-install.sh: one marked block, idempotent, removable"
rc="$HOME/.bashrc"; printf 'alias ll="ls -l"' > "$rc"     # no trailing newline on purpose
bash "$APP/bin/sj-shell-install.sh" >/dev/null
bash "$APP/bin/sj-shell-install.sh" >/dev/null
assert_eq "installed once" "1" "$(grep -c '>>> scrubjay shell integration >>>' "$rc")"
assert_eq "did not splice onto the last line" 'alias ll="ls -l"' "$(head -1 "$rc")"
check "status reports it" bash "$APP/bin/sj-shell-install.sh" --status
assert_contains "sources it through ~/.claude/hooks" "$(cat "$rc")" '/hooks/../bin/sj-shell.sh'
: > "$SANDBOX/claude.calls"
( cd "$work" && bash -ic 'claude --version' ) >/dev/null 2>&1
assert_eq "a new interactive shell has the function" "$work_real|--version" "$(calls)"
bash "$APP/bin/sj-shell-install.sh" --uninstall >/dev/null
assert_eq "uninstall leaves only what was there" 'alias ll="ls -l"' "$(cat "$rc")"
check_fails "status reports it gone" bash "$APP/bin/sj-shell-install.sh" --status

finish
