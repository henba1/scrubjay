#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/sj-keep.sh — an interactive agent runs inside tmux so the terminal closing doesn't kill it.
# What must hold: only interactive TUI launches are wrapped (never -p, --bg, serve, exec,
# --version …); it is off unless configured; it never wraps inside tmux or without a terminal; a
# missing tmux runs the command anyway; the caller's environment reaches the agent even when the tmux
# server's is different; the environment file is private and gone once read.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

KEEP="$APP/bin/sj-keep.sh"
unset TMUX TMUX_PANE SSH_CONNECTION SSH_TTY SCRUBJAY_KEEP

# A stub tmux: sessions are lines in a file. new-session runs the command the way a long-running
# server would — in a STALE environment (env -i plus a different FOO), with TMUX set.
mkdir -p "$SANDBOX/stubbin"
cat > "$SANDBOX/stubbin/faketmux" <<'EOF'
#!/usr/bin/env bash
db="$SANDBOX/tmux.sessions"; touch "$db"
case "$1" in
  has-session) grep -qx "${3#=}" "$db" ;;
  list-sessions) while read -r n; do printf '%s\tdetached\t/w\n' "$n"; done < "$db" ;;
  new-session)
    shift; name="" dir=""
    while [ $# -gt 0 ]; do case "$1" in -s) name="$2"; shift 2 ;; -c) dir="$2"; shift 2 ;; *) break ;; esac; done
    printf '%s\n' "$name" >> "$SANDBOX/tmux.new"
    printf '%s\n' "$name" >> "$db"      # detached: it is still running afterwards
    # $3 is the env file (SELF --inner <file> -- cmd …)
    ls -l "$3" | cut -c1-10 > "$SANDBOX/envfile.mode"
    cd "$dir" && env -i PATH=/usr/bin:/bin HOME=/stale FOO=stale TMUX=/tmp/fake,1,0 TMUX_PANE=%0 SANDBOX="$SANDBOX" "$@" </dev/null
    ;;
esac
EOF
cat > "$SANDBOX/stubbin/agent" <<'EOF'
#!/usr/bin/env bash
printf 'args=%s FOO=%s HOME=%s TMUX=%s pwd=%s\n' "$*" "${FOO:-}" "$HOME" "${TMUX:-}" "$PWD" >> "$SANDBOX/agent.calls"
exit "${AGENT_RC:-0}"
EOF
chmod +x "$SANDBOX/stubbin/faketmux" "$SANDBOX/stubbin/agent"
export PATH="$SANDBOX/stubbin:$PATH" SJ_KEEP_TMUX=faketmux

work="$SANDBOX/my.project"; mkdir -p "$work"; cd "$work" || exit 1

# ex [env…] -- <sj-keep args> : the decision, as a terminal user over SSH would get it
ex() { env SCRUBJAY_KEEP=ssh SSH_CONNECTION="1 2 3 4" SJ_KEEP_ASSUME_TTY=1 "$@"; }
dec() { ex bash "$KEEP" --explain "$@"; }

section "when it wraps at all"
assert_eq "off by default" "direct: SCRUBJAY_KEEP is off" "$(SJ_KEEP_ASSUME_TTY=1 bash "$KEEP" --explain --as claude -- claude)"
# shellcheck disable=SC2016  # written verbatim, expands when the config is sourced
mkdir -p "$HOME/.config/scrubjay"; echo ': "${SCRUBJAY_KEEP:=always}"' > "$HOME/.config/scrubjay/config"
assert_eq "the config file turns it on" "wrap sj-claude-my-project" "$(SJ_KEEP_ASSUME_TTY=1 bash "$KEEP" --explain --as claude -- claude)"
rm "$HOME/.config/scrubjay/config"
assert_eq "ssh mode, local shell" "direct: not an SSH session" "$(SCRUBJAY_KEEP=ssh SJ_KEEP_ASSUME_TTY=1 bash "$KEEP" --explain -- agent)"
assert_eq "ssh mode, over SSH" "wrap sj-agent-my-project" "$(dec -- agent)"
assert_eq "already inside tmux" "direct: already inside tmux" "$(TMUX=x dec -- agent)"
assert_eq "no terminal" "direct: not a terminal" "$(ex SJ_KEEP_ASSUME_TTY=0 bash "$KEEP" --explain -- agent </dev/null)"
assert_eq "no tmux" "direct: tmux is not installed" "$(SJ_KEEP_TMUX=sj-no-such-tmux dec -- agent)"
assert_eq "a bad mode is off" "direct: SCRUBJAY_KEEP='yes' is not off|ssh|always" "$(SCRUBJAY_KEEP=yes SJ_KEEP_ASSUME_TTY=1 bash "$KEEP" --explain -- agent)"

section "only interactive launches of a harness"
for a in "claude" "claude fix the retry" "claude --model opus" "claude -c" "claude --remote-control" \
         "opencode" "opencode -c" "opencode ." "codex" "codex resume" "codex --full-auto"; do
  read -r h rest <<<"$a"
  # shellcheck disable=SC2086
  assert_contains "wraps: $a" "$(dec --as "$h" -- $a)" "wrap"
done
for a in "claude -p hi" "claude --print hi" "claude --bg task" "claude --version" "claude -h" "claude mcp list" \
         "claude agents" "claude attach x" "claude update" "opencode serve" "opencode run hi" "opencode attach u" \
         "opencode export" "codex exec hi" "codex login" "codex --version"; do
  read -r h rest <<<"$a"
  # shellcheck disable=SC2086
  assert_contains "direct: $a" "$(dec --as "$h" -- $a)" "direct: not an interactive"
done
assert_eq "--force wraps whatever the arguments" "wrap sj-claude-my-project" "$(dec --as claude --force -- claude -p x)"
assert_eq "a prompt-shaped codex argument wraps" "wrap sj-codex-my-project" "$(dec --as codex -- codex 'fix the build')"

section "session names"
printf 'sj-agent-my-project\nsj-agent-my-project-2\n' > "$SANDBOX/tmux.sessions"
assert_eq "a taken name gets the next number" "wrap sj-agent-my-project-3" "$(dec -- agent)"
: > "$SANDBOX/tmux.sessions"
assert_eq "/ is root" "wrap sj-agent-root" "$(cd / && dec -- agent)"

section "running it"
: > "$SANDBOX/agent.calls"; rm -f "$SANDBOX/tmux.new"
FOO="caller's" ex bash "$KEEP" --as claude -- agent --model opus 2>"$SANDBOX/err"
assert_eq "started a session, named for the harness" "sj-claude-my-project" "$(cat "$SANDBOX/tmux.new" 2>/dev/null)"
got="$(cat "$SANDBOX/agent.calls")"
assert_contains "the agent got its arguments" "$got" "args=--model opus"
assert_contains "the caller's environment, not the server's" "$got" "FOO=caller's HOME=$HOME"
assert_contains "but tmux's own TMUX kept" "$got" "TMUX=/tmp/fake,1,0"
assert_contains "in the caller's folder" "$got" "pwd=$work"
assert_eq "the environment file is private" "-rw-------" "$(cat "$SANDBOX/envfile.mode")"
left="$(find "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" -maxdepth 1 -name 'sj-keep.*' -newer "$SANDBOX/envfile.mode" 2>/dev/null)"
assert_eq "and gone once read" "" "$left"

: > "$SANDBOX/agent.calls"; : > "$SANDBOX/tmux.sessions"
out="$(AGENT_RC=3 ex bash "$KEEP" -- agent 2>&1)"
assert_eq "a failed start is still run" "1" "$(wc -l < "$SANDBOX/agent.calls" | tr -d ' ')"

printf 'sj-agent-my-project\n' > "$SANDBOX/tmux.sessions"
out="$(ex bash "$KEEP" -- agent 2>&1)"
assert_contains "after detaching, says how to reattach" "$out" "tmux attach -t sj-agent-my-project-2"
: > "$SANDBOX/tmux.sessions"

: > "$SANDBOX/agent.calls"
out="$(SJ_KEEP_TMUX=sj-no-such-tmux ex bash "$KEEP" -- agent x 2>&1)"
assert_contains "no tmux: says so" "$out" "tmux is not installed"
assert_contains "and runs the command anyway" "$(cat "$SANDBOX/agent.calls")" "args=x"
: > "$SANDBOX/agent.calls"
bash "$KEEP" --as claude -- agent -p hi
assert_contains "off: runs the command directly" "$(cat "$SANDBOX/agent.calls")" "TMUX= pwd"

section "ls"
printf 'sj-claude-a\nother\n' > "$SANDBOX/tmux.sessions"
out="$(bash "$KEEP" ls)"
assert_contains "lists kept sessions" "$out" "sj-claude-a"
case "$out" in *other*) _no "hides sessions it didn't make" "$out" ;; *) _ok "hides sessions it didn't make" ;; esac

section "the shell functions"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { skip "$sh: opencode/codex pass through without a terminal" "$sh not installed"; continue; }
  : > "$SANDBOX/agent.calls"
  ln -sf "$SANDBOX/stubbin/agent" "$SANDBOX/stubbin/opencode"
  # shellcheck disable=SC2016  # expands in the inner shell
  ( SCRUBJAY_KEEP=always "$sh" -c '. "$0"; opencode serve --port 1' "$APP/bin/sj-shell.sh" </dev/null >/dev/null 2>&1 )
  assert_contains "$sh: opencode passes through without a terminal" "$(cat "$SANDBOX/agent.calls")" "args=serve --port 1"
done
rm -f "$SANDBOX/stubbin/opencode"

finish
