#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The tmux status bar (bin/sj-status.sh). What must hold: this pane's agent is found by its process,
# a session in a subfolder or another worktree of the repo is the same project and one elsewhere is
# not, a permission prompt shows as waiting, an agent in GreyKnight's pane is labelled gk, the bar
# shortens itself to the client's width, and the menu offers a switch only where tmux can make one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
need_cmd git "sj-status" || { finish; exit; }
export SCRUBJAY_RUN_DIR="$SANDBOX/run" SJ_STATUS_TTL=0 SCRUBJAY_STATUS_DRIFT=off SJ_STATUS_NOW=1800000000
ST="$APP/bin/sj-status.sh"
strip() { sed 's/#\[[^]]*\]//g'; }

# A project with a worktree, and a folder outside git
repo="$SANDBOX/widget" wt="$SANDBOX/widget-feat" plain="$SANDBOX/notes"
git init -q -b main "$repo" && git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" worktree add -q "$wt" -b feat/retry 2>/dev/null
mkdir -p "$wt/src" "$plain"

# Stand-in agents: real processes (the bar checks they live and walks their parents). One is named
# nvim under NVIM_APPNAME=greyknight - an agent in GreyKnight's pane is a child of that Neovim.
# A script, not a copy of sleep: a multi-call coreutils (uutils) picks its tool by name and has no nvim.
mkdir -p "$SANDBOX/bin"; printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$SANDBOX/bin/nvim"; chmod +x "$SANDBOX/bin/nvim"
sleep 300 & A=$!                 # this pane's agent, in the repo
sleep 300 & B=$!                 # another tmux pane, in a subfolder of the worktree
NVIM_APPNAME=greyknight "$SANDBOX/bin/nvim" & G=$!   # in GreyKnight, in the repo
sleep 300 & O=$!                 # a pane in a folder outside git
trap 'kill $A $B $G $O 2>/dev/null' EXIT
sid() { printf '%s1111111-2222-4333-8444-555555555555' "$1"; }
reg() {  # reg <pid> <sid> <status> <cwd> <seconds ago>
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  jq -n --argjson pid "$1" --arg sid "$2" --arg st "$3" --arg cwd "$4" --argjson t $(( (SJ_STATUS_NOW - $5) * 1000 )) \
    '{pid: $pid, sessionId: $sid, status: $st, cwd: $cwd, statusUpdatedAt: $t}' > "$CLAUDE_CONFIG_DIR/sessions/$1.json"
}
reg "$A" "$(sid a)" busy "$repo" 120
reg "$B" "$(sid b)" idle "$wt/src" 720
reg "$G" "$(sid c)" idle "$repo" 60
reg "$O" "$(sid d)" busy "$plain" 30

# A stand-in tmux: the panes as tmux lists them, and the menu it was asked to show
cat > "$SANDBOX/bin/faketmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  list-panes) printf '%s\tsj-claude-widget:0.%%1\n%s\tsj-claude-widget-feat:0.%%2\n%s\tsj-claude-notes:0.%%4\n' $A $B $O ;;
  display-menu) printf '%s\n' "\$@" > "$SANDBOX/menu.args" ;;
  display) echo "\${FAKE_TMUX_VERSION:-3.3a}" ;;
esac
EOF
chmod +x "$SANDBOX/bin/faketmux"; export SJ_STATUS_TMUX="$SANDBOX/bin/faketmux"

section "this pane's agent, its project, the rest"
list="$(bash "$ST" list sj-claude-widget %1)"
row() { awk -F'\t' -v s="$1" '$3 == s' <<<"$list"; }
assert_eq "this pane's: found by its process" "this" "$(row "$(sid a)" | cut -f1)"
assert_eq "its project is the repository, its branch main" "widget	main" "$(row "$(sid a)" | cut -f6,7)"
assert_eq "another worktree's subfolder is the same project" "related" "$(row "$(sid b)" | cut -f1)"
assert_eq "and has its own branch" "feat/retry" "$(row "$(sid b)" | cut -f7)"
assert_eq "an agent in GreyKnight's pane: related, in gk" "related	gk" "$(row "$(sid c)" | cut -f1,8)"
assert_eq "a folder outside git is another project" "other	-" "$(row "$(sid d)" | cut -f1,7)"
assert_eq "how long it has been so" "120" "$(row "$(sid a)" | cut -f5)"

section "a permission prompt is waiting, from the lease"
mkdir -p "$SCRUBJAY_RUN_DIR/live"
jq -n --arg sid "$(sid b)" --argjson ts $(( SJ_STATUS_NOW - 5 )) '{sid: $sid, state: "waiting", ts: $ts}' \
  > "$SCRUBJAY_RUN_DIR/live/$(sid b).lease"
assert_eq "the lease's waiting wins over the registry's idle" "waiting	5" \
  "$(bash "$ST" list sj-claude-widget %1 | awk -F'\t' -v s="$(sid b)" '$3 == s' | cut -f4,5)"

section "the bar"
left="$(bash "$ST" left sj-claude-widget %1 200 "✳ Retry backoff" | strip)"
assert_contains "this session: project ⎇ branch · sid · state age" "$left" "widget ⎇ main · a1111111 · ● working 2m"
assert_contains "a related one with its branch" "$left" "◐ b1111111 feat/retry 5s"
assert_contains "one in GreyKnight: gk, not its folder" "$left" "○ c1111111 gk 1m"
check "the other project's is not named" bash -c '! grep -q d1111111 <<<"$1"' _ "$left"
narrow="$(bash "$ST" left sj-claude-widget %1 60 "✳ Retry backoff" | strip)"
right="$(bash "$ST" right "✳ Retry backoff" 60 | strip)"
check "narrow: left and right fit the width" test $(( ${#narrow} + ${#right} )) -le 60
assert_contains "the related ones counted instead" "$narrow" "+2"
assert_contains "the title without the spinner" "$(bash "$ST" right "✳ Retry backoff" 200 | strip)" "Retry backoff · "
check "narrow: no date" bash -c '! grep -q "· testhost" <<<"$1"' _ "$right"
plain_left="$(bash "$ST" left sj-other %9 200 "" | strip)"
assert_contains "a pane without an agent: host and tmux session" "$plain_left" "testhost · sj-other"
assert_contains "a # in a branch is no tmux format" \
  "$(git -C "$wt" checkout -q -b 'fix#7' && bash "$ST" left sj-claude-widget-feat %2 200 '')" "fix##7"

section "a click on a related session (tmux 3.4 and later)"
raw="$(bash "$ST" left sj-claude-widget %1 200 '')"
check "tmux 3.3: no click ranges, the menu does it" bash -c '! grep -q "range=" <<<"$1"' _ "$raw"
raw="$(FAKE_TMUX_VERSION=3.5a bash "$ST" left sj-claude-widget %1 200 '')"
assert_contains "3.5: the tmux pane's session is a range named by its pane" "$raw" "#[range=user|%2]"
check "one in a Neovim is not (tmux cannot switch to it)" bash -c '! grep -q "range=user|-" <<<"$1"' _ "$raw"
assert_contains "a development build counts by its number" "$(FAKE_TMUX_VERSION=next-3.6 bash "$ST" left sj-claude-widget %1 200 '')" "range=user|%2"

section "the config tmux reads"
if need_cmd tmux "tmux parses tmux/scrubjay.conf"; then
  # tmux expands ${...} in a double-quoted string itself and knows no ${X:-default}: it must parse
  err="$(tmux -L "sjstatus$$" -f /dev/null start-server \; source-file -n "$APP/tmux/scrubjay.conf" 2>&1)"
  assert_eq "tmux parses it without a complaint" "" "$err"
  tmux -L "sjstatus$$" kill-server 2>/dev/null
fi
# what onboard writes into ~/.tmux.conf: a path tmux can expand ($HOME), never ${X:-default}
check "onboard's source-file line is one tmux can read" bash -c '! grep -q "source-file .*:-" "$1"' _ "$APP/bin/onboard.sh"

section "the menu"
bash "$ST" menu /dev/pts/1 sj-claude-widget %1 4
args="$(cat "$SANDBOX/menu.args")"
assert_contains "for that client" "$args" "/dev/pts/1"
assert_contains "options end before the items" "$args" $'\n--\n'
assert_contains "this one is shown, disabled" "$args" "-● a1111111"
assert_contains "another tmux pane: switched to" "$args" "switch-client -t 'sj-claude-widget-feat'"
assert_contains "one in GreyKnight: disabled, and says where" "$args" "-○ c1111111"
check "the other project is not offered" bash -c '! grep -q d1111111 <<<"$1"' _ "$args"
assert_contains "and every tmux session" "$args" "choose-tree -Zs"

finish
