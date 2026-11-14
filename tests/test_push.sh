#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Push to the phone (bin/sj-notify.sh push, called from bin/sj-live.sh). What must hold: a push only
# when nobody is looking (a detached tmux session, or anywhere with SCRUBJAY_PUSH=always); a permission
# prompt at once, a turn ending only after a long turn and with the start of the last reply; one push per
# session and kind within 10 minutes; nothing at all without a server and a topic, or with off; the topic
# never on a command line or in output; the token never on a command line; a failing server fails no
# hook; and no real request, ever: curl and wget are stubs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
export SCRUBJAY_RUN_DIR="$SANDBOX/run" SCRUBJAY_LIVE_PID=$$ SJ_NOTIFY_SETTLE=0 SJ_KEEP_TMUX=faketmux
export SJ_NOTIFY_CURL="$SANDBOX/stubbin/curl" SJ_NOTIFY_WGET="$SANDBOX/stubbin/wget"
unset SCRUBJAY_NOTIFY TMUX TMUX_PANE
S=11111111-2222-4333-8444-555555555555
TOPIC=sekrit-topic-4f9a2c
TOKEN=tk_testtoken0123456789
mkdir -p "$SANDBOX/stubbin" "$SANDBOX/pushes" "$CLAUDE_CONFIG_DIR/projects/-w"
LEASE="$SCRUBJAY_RUN_DIR/live/$S.lease"

# Stubs: each call leaves its argv (args.N), its header file (hdr.N) and its body (body.N) in pushes/.
# STUB_HTTP=fail makes them fail as a refused connection would.
cat > "$SANDBOX/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(ls "$SANDBOX/pushes" | grep -c '^args\.') + 1 ))
printf '%s\n' "curl $*" > "$SANDBOX/pushes/args.$n"
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in @*) cat "${2#@}" > "$SANDBOX/pushes/hdr.$n" ;; esac; shift ;;
    --data-binary) cat "${2#@}" > "$SANDBOX/pushes/body.$n"; shift ;;
  esac
  shift
done
[ "${STUB_HTTP:-}" = fail ] && exit 7
case "$(cat "$SANDBOX/pushes/args.$n")" in *v1/health*) echo '{"healthy":true}' ;; *) echo '{"id":"x"}' ;; esac
EOF
cat > "$SANDBOX/stubbin/wget" <<'EOF'
#!/usr/bin/env bash
n=$(( $(ls "$SANDBOX/pushes" | grep -c '^args\.') + 1 ))
printf '%s\n' "wget $*" > "$SANDBOX/pushes/args.$n"
for a in "$@"; do
  case "$a" in
    --config=*) cat "${a#--config=}" > "$SANDBOX/pushes/hdr.$n" ;;
    --post-file=*) cat "${a#--post-file=}" > "$SANDBOX/pushes/body.$n" ;;
  esac
done
[ "${STUB_HTTP:-}" = fail ] && exit 4
echo '{"id":"x"}'
EOF
# A stub tmux: this test's own process sits in pane %1 of session sj-w; tmux.attached says how many
# clients look at it.
cat > "$SANDBOX/stubbin/faketmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-panes) [ -f "$SANDBOX/tmux.none" ] || printf '%s\t%%1\tsj-w\t%s\n' "$SJ_TEST_PID" "$(cat "$SANDBOX/tmux.attached" 2>/dev/null || echo 0)" ;;
esac
EOF
chmod +x "$SANDBOX/stubbin/"*
export PATH="$SANDBOX/stubbin:$PATH" SJ_TEST_PID=$$
echo 0 > "$SANDBOX/tmux.attached"

# The agent's last reply, longer than a push carries.
long="Done. I could not run the sudo step myself, so please run the script at /tmp/x/run.sh: it restarts the service and reloads the firewall. $(printf 'more words %.0s' $(seq 30))END"
jq -nc '{type: "assistant", sessionId: "'$S'", timestamp: "2026-11-14T09:59:00Z", message: {content: [{type: "text", text: "An earlier reply."}]}}' \
  > "$CLAUDE_CONFIG_DIR/projects/-w/$S.jsonl"
jq -nc --arg t "$long" '{type: "assistant", sessionId: "'$S'", timestamp: "2026-11-14T10:00:00Z", message: {content: [{type: "text", text: $t}]}}' \
  >> "$CLAUDE_CONFIG_DIR/projects/-w/$S.jsonl"

pushes() { find "$SANDBOX/pushes" -name 'args.*' | wc -l | tr -d ' '; }
# The push is sent detached; wait until it lands (or long enough to say it did not).
settle() { local _; for _ in $(seq 30); do [ "$(pushes)" -ge "$1" ] && break; sleep 0.1; done; sleep 0.3; }
last_body() { cat "$SANDBOX/pushes/body.$(pushes)" 2>/dev/null; }
mark() { bash "$APP/bin/sj-live.sh" mark "$S" "$1" /w; }
long_turn() {  # the running turn began <secs> ago
  jq -c --argjson t "$(( $(date +%s) - $1 ))" '.turn = $t' "$LEASE" > "$LEASE.x" && mv "$LEASE.x" "$LEASE"
}
forget() { rm -f "$SCRUBJAY_RUN_DIR/notify/$S".*.push; }   # past the 10-minute window

section "no server, no topic: nothing"
mark idle; mark working; mark waiting; mark idle; settle 1
assert_eq "nothing pushed" 0 "$(pushes)"
export SCRUBJAY_NTFY_URL=http://ntfy.example:8080
mark working; mark waiting; settle 1
assert_eq "a URL alone: nothing" 0 "$(pushes)"

section "a permission prompt in a detached tmux session pushes, high"
export SCRUBJAY_NTFY_TOPIC="$TOPIC"
mark idle; mark working; mark waiting; settle 1
assert_eq "one push" 1 "$(pushes)"
b="$(last_body)"
assert_eq "to the topic" "$TOPIC" "$(jq -r .topic <<<"$b")"
assert_eq "priority high" 4 "$(jq -r .priority <<<"$b")"
assert_contains "the title says what it waits for" "$(jq -r .title <<<"$b")" "w on testhost: waiting for a permission"
assert_contains "names the session" "$(jq -r .message <<<"$b")" "session: ${S:0:8} · tmux sj-w"
assert_contains "and how to get to it: the front door, sj, now that it exists" "$(jq -r .message <<<"$b")" "attach: sj attach 11111111"
assert_contains "and the folder" "$(jq -r .message <<<"$b")" "folder: /w"
assert_contains "POSTed to the server's root" "$(cat "$SANDBOX/pushes/args.1")" "http://ntfy.example:8080/"
case "$(cat "$SANDBOX/pushes/args.1")" in *"$TOPIC"*) _no "the topic is not on the command line" "it was" ;; *) _ok "the topic is not on the command line" ;; esac

section "the same again within 10 minutes: dropped"
mark working; mark waiting; settle 2
assert_eq "still one" 1 "$(pushes)"

section "a turn ending: only a long one, with the start of the reply"
mark idle; settle 2
assert_eq "a short turn: nothing" 1 "$(pushes)"
mark working; long_turn 400; mark idle; settle 2
assert_eq "a long turn: pushed" 2 "$(pushes)"
b="$(last_body)"
assert_eq "priority default" 3 "$(jq -r .priority <<<"$b")"
assert_contains "the title says whose turn" "$(jq -r .title <<<"$b")" "your turn (6 min of work)"
assert_contains "the last reply's start" "$(jq -r .message <<<"$b")" "Done. I could not run the sudo step myself"
case "$(jq -r .message <<<"$b")" in *"earlier reply"*) _no "the last reply only" "an earlier one too" ;; *) _ok "the last reply only" ;; esac
case "$(jq -r .message <<<"$b")" in *END*) _no "cut to about 200 characters" "the whole reply went" ;; *) _ok "cut to about 200 characters" ;; esac
mark working; long_turn 400; mark waiting; mark idle; settle 3
assert_eq "the turn's start carries across a permission prompt, and a repeat is dropped" 2 "$(pushes)"
forget
mark working; long_turn 400; mark waiting; settle 3
forget; mark idle; settle 4
assert_eq "past the window: a prompt and the long turn's end both push" 4 "$(pushes)"
assert_contains "the end counted from the turn's start" "$(jq -r .title <<<"$(last_body)")" "your turn (6 min"
forget; mark working; long_turn 20; SCRUBJAY_PUSH_MIN_TURN=10 mark idle; settle 5
assert_eq "SCRUBJAY_PUSH_MIN_TURN lowers the bar" 5 "$(pushes)"

section "someone is looking: nothing (detached), or a push anyway (always)"
forget; echo 1 > "$SANDBOX/tmux.attached"
mark working; mark waiting; settle 6
assert_eq "attached: nothing" 5 "$(pushes)"
SCRUBJAY_PUSH=always mark working; SCRUBJAY_PUSH=always mark waiting; settle 6
assert_eq "attached, always: pushed" 6 "$(pushes)"
forget; echo 0 > "$SANDBOX/tmux.attached"; touch "$SANDBOX/tmux.none"
mark working; mark waiting; settle 7
assert_eq "not in tmux: nothing" 6 "$(pushes)"
SCRUBJAY_PUSH=always mark working; SCRUBJAY_PUSH=always mark waiting; settle 7
assert_eq "not in tmux, always: pushed" 7 "$(pushes)"
assert_contains "and says it is not in tmux" "$(jq -r .message <<<"$(last_body)")" "attach: not in tmux (pid $$)"
rm -f "$SANDBOX/tmux.none"

section "off: nothing"
forget
SCRUBJAY_PUSH=off mark working; SCRUBJAY_PUSH=off mark waiting; settle 8
assert_eq "SCRUBJAY_PUSH=off" 7 "$(pushes)"

section "another process over a dead one's lease is not a turn ending"
jq -c '.state = "working" | .pid = "999999"' "$LEASE" > "$LEASE.x" && mv "$LEASE.x" "$LEASE"
long_turn 4000; mark idle; settle 8
assert_eq "nothing" 7 "$(pushes)"

section "a token goes in a header file, never on the command line"
export SCRUBJAY_NTFY_TOKEN="$TOKEN"
forget; mark working; mark waiting; settle 8
n="$(pushes)"
assert_contains "sent as a bearer token" "$(cat "$SANDBOX/pushes/hdr.$n")" "Authorization: Bearer $TOKEN"
case "$(cat "$SANDBOX/pushes/args.$n")" in *"$TOKEN"*) _no "not in argv" "it was" ;; *) _ok "not in argv" ;; esac

section "without curl, wget"
forget; SJ_NOTIFY_CURL="$SANDBOX/no-curl" mark working; SJ_NOTIFY_CURL="$SANDBOX/no-curl" mark waiting; settle 9
n="$(pushes)"
assert_contains "wget posts it" "$(cat "$SANDBOX/pushes/args.$n")" "wget "
assert_eq "the same body" "$TOPIC" "$(jq -r .topic <<<"$(last_body)")"
assert_contains "the token in its config file" "$(cat "$SANDBOX/pushes/hdr.$n")" "header = Authorization: Bearer $TOKEN"
case "$(cat "$SANDBOX/pushes/args.$n")" in *"$TOKEN"*|*"$TOPIC"*) _no "no secret in its argv" "there was" ;; *) _ok "no secret in its argv" ;; esac
unset SCRUBJAY_NTFY_TOKEN

section "the hooks stay silent and succeed, even when the server fails"
forget; mark working
out="$(printf '{"session_id":"%s","hook_event_name":"PermissionRequest","cwd":"/w"}' "$S" | STUB_HTTP=fail bash "$APP/hooks/live-session.sh")"; rc=$?
assert_eq "prints nothing" "" "$out"
assert_eq "exits 0" 0 "$rc"
for _ in $(seq 30); do grep -q fail "$SCRUBJAY_RUN_DIR/notify/last" 2>/dev/null && break; sleep 0.1; done
assert_contains "the failure is noted for sj-doctor" "$(cat "$SCRUBJAY_RUN_DIR/notify/last" 2>/dev/null)" "fail waiting ${S:0:8}"
case "$(cat "$SCRUBJAY_RUN_DIR/notify/last")" in *"$TOPIC"*) _no "without the topic" "it was there" ;; *) _ok "without the topic" ;; esac

section "test-push and health"
before="$(pushes)"
out="$(bash "$APP/bin/sj-notify.sh" test-push 2>&1)"; rc=$?
assert_eq "test-push: exits 0" 0 "$rc"
assert_contains "says it went" "$out" "test push sent to http://ntfy.example:8080"
assert_eq "one post" $((before + 1)) "$(pushes)"
case "$out" in *"$TOPIC"*) _no "the topic is not printed" "$out" ;; *) _ok "the topic is not printed" ;; esac
check_fails "a server that refuses: exits 1" env STUB_HTTP=fail bash "$APP/bin/sj-notify.sh" test-push
check "health: 0 when the server says healthy" bash "$APP/bin/sj-notify.sh" health
check_fails "no topic: test-push says so and fails" env -u SCRUBJAY_NTFY_TOPIC bash "$APP/bin/sj-notify.sh" test-push

section "the topic is set in the config file, too"
unset SCRUBJAY_NTFY_URL SCRUBJAY_NTFY_TOPIC
mkdir -p "$HOME/.config/scrubjay"
printf ': "${SCRUBJAY_NTFY_URL:=http://ntfy.example:8080}"\n: "${SCRUBJAY_NTFY_TOPIC:=%s}"\n' "$TOPIC" > "$HOME/.config/scrubjay/config"
before="$(pushes)"; forget
mark working; mark waiting; settle $((before + 1))
assert_eq "pushed from the config's settings" $((before + 1)) "$(pushes)"

section "sj-doctor: the topic masked, and a post only with --push"
before="$(pushes)"
out="$(bash "$APP/bin/sj-doctor.sh" harnesses 2>&1)"
assert_contains "reports the push" "$out" "push: detached, to http://ntfy.example:8080, topic hidden (${#TOPIC} chars)"
assert_contains "the server answers" "$out" "the server answers"
case "$out" in *"$TOPIC"*) _no "never the topic" "$out" ;; *) _ok "never the topic" ;; esac
assert_eq "a health check, no post" "" "$(cat "$SANDBOX/pushes/body.$((before + 1))" 2>/dev/null)"
out="$(bash "$APP/bin/sj-doctor.sh" --push harnesses 2>&1)"
assert_contains "--push: a test push went out" "$out" "a test push went out"
assert_eq "--push: it posted" "$TOPIC" "$(jq -r .topic <<<"$(last_body)")"
out="$(STUB_HTTP=fail bash "$APP/bin/sj-doctor.sh" harnesses 2>&1)"
assert_contains "a server that does not answer is a failure" "$out" "does not answer its health check"
: > "$HOME/.config/scrubjay/config"
assert_contains "none configured: a note" "$(bash "$APP/bin/sj-doctor.sh" harnesses 2>&1)" "push: off"
assert_contains "half configured: a failure" "$(SCRUBJAY_NTFY_URL=http://x bash "$APP/bin/sj-doctor.sh" harnesses 2>&1)" "SCRUBJAY_NTFY_TOPIC is not set"
assert_contains "a bad mode: a failure" "$(SCRUBJAY_NTFY_URL=http://x SCRUBJAY_NTFY_TOPIC=t SCRUBJAY_PUSH=yes bash "$APP/bin/sj-doctor.sh" harnesses 2>&1)" "is not off, detached or always"

finish
