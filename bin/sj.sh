#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# sj: one front door for finding a session and getting back into it, wherever it runs.
#
#   usage: sj [pick] [--all] [--live]            a picker: this project's sessions, live and past, on
#                                                every machine; Enter takes you back into the chosen one
#          sj ls                                 every agent on every machine, and its state
#          sj attach <tmux-name|sid|sid8>        back into a running one: tmux here, over ssh elsewhere
#          sj resume [--force] <sid|sid8> [claude args…]
#                                                continue one, by whichever path fits (it says which)
#          sj view [<sid|sid8>|<project>]        the session map in a browser, on that session or project
#          sj where <sid|sid8>                   the tmux session holding it here (for scripts and ssh)
#          sj help
#
# States: working (mid-turn), waiting (at a permission prompt), idle (its turn is over), ended (closed
# cleanly), exited (the process went without SessionEnd, or sj-keep holds the pane of an agent that
# exited), reaped (stopped by bin/sj-reap.sh).
#
# Before this, getting back to a session took one of six commands, and choosing the right one meant
# knowing where the agent was: `tmux attach` (still running, detached), `claude -c` or `claude
# --resume <sid>` (stopped, here), `claude resume <sid>` or /sjresume (recorded on another machine),
# and `sj-reap.sh ls` (what is running at all). Picking wrong is not harmless: a resume while the
# first copy still runs loads the conversation into a second process, and the two diverge. sj wraps
# all of them and makes that choice from what scrubjay already knows.
#
# Where the knowledge comes from:
#   here       the harness's registry of live processes joined with tmux panes, exactly as
#              bin/sj-reap.sh reads it (`sj-reap.sh rows`), so the reaper and sj never disagree about
#              which agent sits in which pane. Plus this machine's leases (<run>/live/*.lease) for
#              sessions that ended (cleanly) or exited (the process went without saying so).
#   elsewhere  the leases other hosts relayed into the archive, <archive>/<host>/live/*.lease, the
#              ones /sjview reads. They are snapshots from that host's last publish: no process there
#              can be asked from here, so `sj ls` says "as of <time>" rather than pretend.
#   reaped     <run>/reap.log, where bin/sj-reap.sh names every agent it stopped.
#   topics     the catalogue (logs/<host>.log), via sj_log_catalogue.
#
# `sj resume` takes the first of these that applies, and says which:
#   1. running here in tmux            attach to it (a second copy would diverge)
#   2. running on another host         offer: attach there over ssh, or hand it off anyway
#   3. stopped, transcript here        cd <its folder> && claude --resume <sid>
#   4. not on this machine             the cross-machine hand-off, bin/sj-claude-resume.sh
# It never starts a second copy of a live session without --force. Running here outside tmux (a
# plain terminal) is refused too: there is nothing to attach to, and the other copy is real.
#
# Other hosts are reached by their SSH config alias. SCRUBJAY_SSH_HOSTS="host=alias …" names them
# when the alias differs from the scrubjay host name; otherwise the host name counts as an alias
# when `ssh -G` shows a Host stanza for it (a HostName other than the name itself). With neither,
# sj prints what to run on that host and stops: an ssh to a guessed name is worse than no ssh.
#
# SCRUBJAY_SJ_RECENT (seconds, default 86400): how far back `sj ls` shows ended and exited sessions.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"
sj_load_config

TMUX_BIN="${SJ_KEEP_TMUX:-tmux}"              # tests point these at stubs
SSH_BIN="${SJ_SSH:-ssh}"
CLAUDE_BIN="${SCRUBJAY_CLAUDE_BIN:-claude}"
RECENT="${SCRUBJAY_SJ_RECENT:-86400}"
LEASE_MAX=604800                              # a host deletes its own leases at 7 days (sj-live.sh)
RUN="$(sj_progress_dir)"
NOW="$(date +%s)"
TAB="$(printf '\t')"
ME="$(sj_host)"

say() { echo "sj: $*" >&2; }

age() {  # age <seconds> -> 3d4h, 5h12m, 7m (sj-reap's format)
  local s="$1"
  [ "$s" -lt 0 ] 2>/dev/null && s=0
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

stamp() {  # stamp <epoch> -> HH:MM today, else YYYY-MM-DD HH:MM
  local s; s="$(sj_epoch_stamp "$1")"
  if [ "${s%% *}" = "$(sj_epoch_ymd "$NOW")" ]; then printf '%s' "${s#* }"; else printf '%s' "$s"; fi
}

is_id() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; }
# A session id as typed: at least 4 characters of one (a shorter prefix matches half the catalogue)
is_sid() { is_id "$1" && [ "${#1}" -ge 4 ]; }

# The archive on this filesystem, resolved the way bin/sj-view.sh does: the NAS mount, or the git
# backend's clone. rsync-wg hosts have none (their relay key is write-only), so they see only here.
archive_root() {
  local c="${SCRUBJAY_LOCAL_CHATS:-}"
  if [ -z "$c" ] && [ "${SCRUBJAY_TRANSCRIPT_BACKEND:-}" = git ]; then
    c="$(sj_chats)"; [ -n "$c" ] && [ -d "$c/.git" ] || c=""
  fi
  [ -n "$c" ] && [ -d "$c" ] && printf '%s' "$c"
}

# leases <dir> — TSV <sid> <state> <ts> <cwd> <pid> <start>, one per readable *.lease in <dir>.
# One jq over all of them; a file that is not a lease (a relay probe, a half-written one) is skipped.
leases() {
  local f
  for f in "$1"/*.lease; do [ -f "$f" ] && { cat "$f"; echo; }; done |
    jq -rR 'fromjson? | select(type == "object" and (.sid | type) == "string" and .sid != "")
      | [.sid, (.state // "idle"), (.ts | if type == "number" then floor else 0 end | tostring), (.cwd // "" | if . == "" then "-" else . end),
         (.pid // "" | tostring | if . == "" then "-" else . end), (.start // "" | if . == "" then "-" else . end)]
      | @tsv' 2>/dev/null
}

# collect — every session sj knows of, TSV:
#   <src here|relay> <host> <sid|-> <state> <ts> <tmux|-> <attached 0|1> <cwd|-> <pid|->
# ts is the newest sign of life (here: sj-reap's reading; relayed: the lease's own time).
collect() {
  local kind a b c d e f g h rest live="" sid state ts cwd pid start cur root dir host
  while IFS="$TAB" read -r kind a b c d e f g h rest; do
    case "$kind" in
      agent)  # sid pid state last session pane attached cwd …
        printf 'here\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ME" "$a" "$c" "$d" "$e" "$g" "$h" "$b"
        live="$live $a" ;;
      empty)  # pane session idle line: sj-keep holds the pane of an agent that exited
        printf 'here\t%s\t-\texited\t%s\t%s\t0\t-\t-\n' "$ME" "$((NOW - ${c:-0}))" "$b" ;;
    esac
  done < <(SJ_KEEP_TMUX="$TMUX_BIN" bash "$APP/bin/sj-reap.sh" rows 2>/dev/null)
  # This machine's leases: what the registry no longer lists. A lease still saying working/idle
  # whose process is gone (or is a stranger: pids come round again) is a session that exited
  # without SessionEnd; one whose process is still there is another harness's live session.
  while IFS="$TAB" read -r sid state ts cwd pid start; do
    case " $live " in *" $sid "*) continue ;; esac
    if [ "$state" != ended ] && [ "$pid" != - ] && kill -0 "$pid" 2>/dev/null; then
      cur="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')"
      if [ "$start" = - ] || [ "$start" = "$cur" ]; then
        printf 'here\t%s\t%s\t%s\t%s\t-\t0\t%s\t%s\n' "$ME" "$sid" "$state" "$ts" "$cwd" "$pid"
        continue
      fi
    fi
    [ $((NOW - ts)) -lt "$RECENT" ] || continue
    [ "$state" = ended ] || state=exited
    printf 'here\t%s\t%s\t%s\t%s\t-\t0\t%s\t-\n' "$ME" "$sid" "$state" "$ts" "$cwd"
  done < <(leases "$RUN/live")
  root="$(archive_root)" || return 0
  for dir in "$root"/*/live; do
    [ -d "$dir" ] || continue
    host="$(basename "$(dirname "$dir")")"
    [ "$host" = "$ME" ] && continue          # our own relayed copy: the live reading above is better
    is_id "${host//./}" || continue
    while IFS="$TAB" read -r sid state ts cwd pid start; do
      if [ "$state" = ended ]; then [ $((NOW - ts)) -lt "$RECENT" ] || continue
      else [ $((NOW - ts)) -lt "$LEASE_MAX" ] || continue; fi
      printf 'relay\t%s\t%s\t%s\t%s\t-\t0\t%s\t-\n' "$host" "$sid" "$state" "$ts" "$cwd"
    done < <(leases "$dir")
  done
}

live_state() { case "$1" in working|waiting|idle) return 0 ;; esac; return 1; }

topics() { sj_log_catalogue 2>/dev/null | cut -f3,5; }   # TSV <sid> <topic>

# reaped — TSV <stamp> <sid> <tmux> <reason> <cwd>, the newest line per session, newest first
reaped() {
  [ -f "$RUN/reap.log" ] || return 0
  grep -F ' reaped ' "$RUN/reap.log" 2>/dev/null |
    sed -n "s/^\([0-9-]* [0-9:]*\) reaped \([A-Za-z0-9_-]*\) pid [0-9]* (\([^,]*\), \(.*\)) — resume: cd \(.*\) && claude --resume .*/\1$TAB\2$TAB\3$TAB\4$TAB\5/p" |
    awk -F '\t' '{ line[NR] = $0; sid[NR] = $2 } END { for (i = NR; i > 0; i--) if (!seen[sid[i]]++) print line[i] }'
}

# ── sj ls ──────────────────────────────────────────────────────────────────────────────────────────
cmd_ls() {
  local rows src host sid state ts tmux att cwd pid rank col root top gone
  rows="$(collect)"
  root="$(archive_root)"
  top="$(mktemp)"; topics > "$top"
  gone="$(reaped | cut -f2)"
  {
    while IFS="$TAB" read -r src host sid state ts tmux att cwd pid; do
      [ -n "$src" ] || continue
      # its SessionEnd came from the reaper's SIGTERM: say so, the section below has the way back
      [ "$src$state" = hereended ] && grep -qxF "$sid" <<<"$gone" && state=reaped
      if [ "$src" = relay ]; then col="as of $(stamp "$ts")"
      elif [ "$tmux" != - ]; then col="$tmux"; [ "$att" = 1 ] && col="$col*"
      elif live_state "$state"; then col="(no tmux)"
      else col="-"; fi
      if live_state "$state"; then [ "$src" = here ] && rank=0 || rank=1; else rank=2; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$ts" "$host" "$sid" "$state" "$(age $((NOW - ts)))" "$col" \
        "$([ "$cwd" = - ] && echo - || basename "$cwd")"
    done <<<"$rows"
  } | sort -t "$TAB" -k1,1n -k2,2nr | awk -F '\t' -v topics="$top" '
    BEGIN { while ((getline l < topics) > 0) { split(l, f, "\t"); t[f[1]] = f[2] } }
    NR == 1 { printf "%-10s %-8s %-8s %-7s %-30s %-20s %s\n", "HOST", "SID", "STATE", "IDLE", "TMUX", "FOLDER", "TOPIC" }
    { printf "%-10s %-8s %-8s %-7s %-30s %-20s %s\n", $3, substr($4, 1, 8), $5, $6, substr($7, 1, 30), substr($8, 1, 20),
        substr(($4 in t) ? t[$4] : "", 1, 50) }
    END { if (NR == 0) print "no sessions known, here or relayed" }'
  rm -f "$top"
  echo "* attached   as of: a relayed snapshot from that host's last publish, its process not checked"
  [ -n "$root" ] || echo "(no archive on this machine: other hosts are not shown)"
  local stamp_ sid_ tmux_ reason cwd_ shown=0
  while IFS="$TAB" read -r stamp_ sid_ tmux_ reason cwd_; do
    [ -n "$sid_" ] || continue
    awk -F '\t' -v s="$sid_" '$1 == "here" && $3 == s && ($4 == "working" || $4 == "waiting" || $4 == "idle") {f=1} END {exit !f}' <<<"$rows" && continue
    [ "$shown" = 0 ] && printf '\nstopped by sj-reap (its screen was saved first):\n'
    printf '  %-16s %-8s %-28s %-24s sj resume %s\n' "$stamp_" "${sid_:0:8}" "${tmux_:0:28}" "${reason:0:24}" "${sid_:0:8}"
    printf '  %-16s %s\n' "" "(cd $(sj_pretty_path "$cwd_") && claude --resume $sid_)"
    shown=$((shown + 1)); [ "$shown" -ge 5 ] && break
  done < <(reaped)
  printf '\nattach: sj attach <tmux-name|sid8>   resume: sj resume <sid8>\n'
}

# ── sj rows: what the picker reads ────────────────────────────────────────────────────────────────
# L <src> <host> <sid> <state> <ts> <tmux> <attached> <cwd> <pid>   collect's rows, reaped marked
# C <ts> <host> <sid> <cwd> <topic> <harness> <summary>             the catalogue, newest first
cmd_rows() {
  local gone src host sid state ts tmux att cwd pid
  gone="$(reaped | cut -f2)"
  while IFS="$TAB" read -r src host sid state ts tmux att cwd pid; do
    [ -n "$src" ] || continue
    [ "$src$state" = hereended ] && grep -qxF "$sid" <<<"$gone" && state=reaped
    printf 'L\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$src" "$host" "$sid" "$state" "$ts" "$tmux" "$att" "$cwd" "$pid"
  done < <(collect)
  sj_log_catalogue 2>/dev/null | sed 's/^/C\t/'
}

cmd_pick() {
  command -v python3 >/dev/null 2>&1 || { say "the picker needs python3; sj ls lists the sessions"; return 1; }
  exec python3 "$APP/bin/sj-pick.py" "$@"
}

# The project of the folder sj runs in, as the map's lanes name one: the last part of a session's
# folder. The first that has sessions of: this folder, the ones above it up to its git repository's
# top (else up to, not including, $HOME), then the repository's own name, which a worktree shares.
here_project() {
  local names d top="" common="" name
  names="$(sj_log_catalogue 2>/dev/null | awk -F '\t' '{ sub(/\/+$/, "", $4); sub(/.*\//, "", $4); print $4 }' | sort -u)"
  if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    common="$(git rev-parse --git-common-dir 2>/dev/null)"   # relative to here on older git: made absolute
    common="$(cd "$common" 2>/dev/null && pwd -P)"
  fi
  d="$(pwd -P)"
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -z "$top" ] && [ "$d" = "$(cd "$HOME" 2>/dev/null && pwd -P)" ] && break
    name="$(basename "$d")"
    grep -qxF -- "$name" <<<"$names" && { printf '%s\n' "$name"; return 0; }
    [ -n "$top" ] && [ "$d" = "$(cd "$top" && pwd -P)" ] && break
    d="$(dirname "$d")"
  done
  case "$common" in
    "")     return 0 ;;
    */.git) name="$(basename "$(dirname "$common")")" ;;
    *)      name="$(basename "${common%.git}")" ;;
  esac
  grep -qxF -- "$name" <<<"$names" && printf '%s\n' "$name"
  return 0
}

# sj view [<sid|sid8>|<project>] — bin/sj-view.sh, opened on a session when given (part of) its id;
# alone, on the project of the folder it runs in, as `sj` opens the picker there
cmd_view() {
  local want="${1:-}" sid
  [ -n "$want" ] && [ "${want#-}" = "$want" ] && shift || want=""
  if [ -n "$want" ] && is_sid "$want" && sid="$(pick "$want" "$(collect)")" && [ -n "$sid" ]; then
    exec bash "$APP/bin/sj-view.sh" start --sid "$sid" "$@"
  fi
  [ -n "$want" ] || want="$(here_project)"
  exec bash "$APP/bin/sj-view.sh" start ${want:+"$want"} "$@"
}

# ── resolving what the user typed ────────────────────────────────────────────────────────────────
# Every session id sj could mean: the ones in <rows>, this machine's transcripts, the catalogue.
# A prefix (the 8-character handle sj_session_handle gives a Claude id, or more) matches the way it
# does for bin/sj-claude-resume.sh; several distinct sessions are listed, never guessed between.
# What nobody here knows is passed on whole: sj_archive_resolve, behind sj-resume.sh, asks the archive.
resolve() {  # resolve <want> <rows> — the matching full ids, one per line
  local want="$1" proj
  proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  { printf '%s\n' "$2" | cut -f3
    find "$proj" -mindepth 2 -maxdepth 2 -type f -name "$want*.jsonl" 2>/dev/null | sed 's#.*/##; s#\.jsonl$##'
    sj_log_catalogue 2>/dev/null | cut -f3
  } | awk -v p="$want" 'length($0) >= length(p) && index(tolower($0), tolower(p)) == 1 && $0 != "-"' | sort -u
}

ambiguous() {  # ambiguous <want> <ids> <rows>
  local s row cat n=0
  cat="$(sj_log_catalogue 2>/dev/null)"
  say "'$1' matches $(printf '%s\n' "$2" | grep -c .) sessions, give more of the id:"
  while IFS= read -r s; do
    [ "$((n += 1))" -gt 12 ] && { echo "    … and $(( $(printf '%s\n' "$2" | grep -c .) - 12 )) more" >&2; break; }
    row="$(awk -F '\t' -v s="$s" '$3 == s {print $2 " " $4 " " $8; exit}' <<<"$3")"
    [ -n "$row" ] || row="$(awk -F '\t' -v s="$s" '$3 == s {print $2 " " $1 " " $4; exit}' <<<"$cat")"
    printf '    %-36s  %s  %s\n' "$s" "${row:-(a transcript here)}" \
      "$(awk -F '\t' -v s="$s" '$3 == s {print substr($5, 1, 48); exit}' <<<"$cat")" >&2
  done <<<"$2"
}

# pick <want> <rows> — the one full id, or "" for an id nobody here knows (the archive may); 2 when
# ambiguous (called in $(…), so the caller returns it)
pick() {
  local ids n
  ids="$(resolve "$1" "$2")"
  n="$(printf '%s' "$ids" | grep -c . || true)"
  if [ "$n" -gt 1 ]; then ambiguous "$1" "$ids" "$2"; return 2; fi
  printf '%s' "$ids"
}

# ── getting in ──────────────────────────────────────────────────────────────────────────────────────
tmux_attach() {  # tmux_attach <name> — never returns
  if [ -n "${TMUX:-}" ]; then exec "$TMUX_BIN" switch-client -t "=$1"; fi
  exec "$TMUX_BIN" attach-session -t "=$1"
}

ssh_alias() {  # ssh_alias <host> — the SSH config alias that reaches <host>, or 1
  local pair hn
  for pair in ${SCRUBJAY_SSH_HOSTS:-}; do
    [ "${pair%%=*}" = "$1" ] && [ -n "${pair#*=}" ] && { printf '%s' "${pair#*=}"; return 0; }
  done
  sj_has "$SSH_BIN" || return 1
  hn="$("$SSH_BIN" -G "$1" 2>/dev/null | awk '/^hostname / {print $2; exit}')"
  [ -n "$hn" ] && [ "$hn" != "$1" ] && { printf '%s' "$1"; return 0; }
  return 1
}

remote_attach() {  # remote_attach <host> <sid> — never returns on success
  local host="$1" sid="$2" alias name
  if ! alias="$(ssh_alias "$host")"; then
    say "no SSH alias is known for '$host', and sj does not guess one. On $host, run:"
    echo "    sj attach ${sid:0:8}"
    say "(or name it: SCRUBJAY_SSH_HOSTS=\"$host=<ssh-alias>\" in ~/.config/scrubjay/config)"
    return 1
  fi
  # Which tmux session holds it is only known there: ask that host's own sj, non-interactively.
  # shellcheck disable=SC2016  # expands on the remote host
  name="$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=8 "$alias" \
    'bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/../bin/sj.sh" where '"$sid" 2>/dev/null | head -n 1)"
  if [ -z "$name" ] || ! is_id "$name"; then
    say "found no tmux session holding ${sid:0:8} on $host: it may have ended since that snapshot, run"
    say "outside tmux there, or $host's scrubjay may predate sj. Look for yourself:"
    echo "    $SSH_BIN -t $alias    then    sj ls"
    return 1
  fi
  say "attaching over ssh: $SSH_BIN -t $alias tmux attach -t =$name"
  exec "$SSH_BIN" -t "$alias" tmux attach-session -t "=$name"
}

# launch <cmd…> — run an agent the way the shell integration would: through sj-keep (so it lands in
# tmux when SCRUBJAY_KEEP says so), but without its "attach instead?" question, which guesses by
# folder where sj already looked by id. Never returns.
launch() {
  if [ -z "${TMUX:-}" ] && [ -t 0 ] && [ -t 1 ]; then
    exec bash "$APP/bin/sj-keep.sh" --as claude --force --no-offer -- "$@"
  fi
  exec "$@"
}

# local_here <sid> <rows> — this machine's live copies of <sid>, detached tmux first
local_here() {
  awk -F '\t' -v s="$1" '$1 == "here" && $3 == s && ($4 == "working" || $4 == "waiting" || $4 == "idle") {
    print (($6 == "-") ? 2 : ($7 == 1) ? 1 : 0) "\t" $0 }' <<<"$2" | sort -t "$TAB" -k1,1n | cut -f2-
}

# remote_live <sid> <rows> — the newest relayed live lease of <sid> on another host
remote_live() {
  awk -F '\t' -v s="$1" '$1 == "relay" && $3 == s && ($4 == "working" || $4 == "waiting" || $4 == "idle")' <<<"$2" |
    sort -t "$TAB" -k5,5nr | head -n 1
}

cmd_where() {
  local want="${1:-}" rows sid
  is_sid "$want" || { echo "usage: sj where <sid|sid8>" >&2; return 2; }
  rows="$(collect)"
  sid="$(pick "$want" "$rows")" || return 2
  [ -n "$sid" ] || return 1
  local_here "$sid" "$rows" | awk -F '\t' '$6 != "-" {print $6; exit}' | grep .
}

cmd_attach() {
  local want="${1:-}" rows sid hit host tmux att pid
  [ -n "$want" ] || { echo "usage: sj attach <tmux-name|sid|sid8>" >&2; return 2; }
  if sj_has "$TMUX_BIN" && "$TMUX_BIN" has-session -t "=$want" 2>/dev/null; then
    say "attaching to tmux session '$want'"; tmux_attach "$want"
  fi
  is_sid "$want" || { say "no tmux session '$want' here, and it is not a session id"; return 1; }
  rows="$(collect)"
  sid="$(pick "$want" "$rows")" || return 2
  [ -n "$sid" ] || { say "no session matches '$want' (sj ls shows what runs where)"; return 1; }
  hit="$(local_here "$sid" "$rows" | head -n 1)"
  if [ -n "$hit" ]; then
    IFS="$TAB" read -r _ _ _ _ _ tmux att _ pid <<<"$hit"
    if [ "$tmux" = - ]; then
      say "${sid:0:8} runs here outside tmux (pid $pid), in the terminal it was started from: nothing to attach to."
      return 1
    fi
    say "attaching to tmux session '$tmux'$([ "$att" = 1 ] && echo ', already attached elsewhere (tmux shares it)')"
    tmux_attach "$tmux"
  fi
  hit="$(remote_live "$sid" "$rows")"
  if [ -n "$hit" ]; then
    host="$(cut -f2 <<<"$hit")"
    say "${sid:0:8} was $(cut -f4 <<<"$hit") on '$host' as of $(stamp "$(cut -f5 <<<"$hit")")"
    remote_attach "$host" "$sid"; return 1
  fi
  hit="$(awk -F '\t' -v s="$sid" '$3 == s' <<<"$rows" | sort -t "$TAB" -k5,5nr | head -n 1)"
  if [ -n "$hit" ]; then
    say "${sid:0:8} is not running: $(cut -f4 <<<"$hit") on '$(cut -f2 <<<"$hit")' at $(stamp "$(cut -f5 <<<"$hit")")."
  else
    say "${sid:0:8} is not running anywhere sj can see."
  fi
  say "to continue it:  sj resume ${sid:0:8}"
  return 1
}

cmd_resume() {
  local force=0 want="" rows sid hit host t cwd proj ans state tmux att pid
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) if [ -z "$want" ]; then want="$1"; else rest+=("$1"); fi ;;
    esac
    shift
  done
  is_sid "$want" || { echo "usage: sj resume [--force] <sid|sid8> [claude args…]" >&2; return 2; }
  rows="$(collect)"
  sid="$(pick "$want" "$rows")" || return 2

  if [ -n "$sid" ]; then
    # 1. running here
    hit="$(local_here "$sid" "$rows" | head -n 1)"
    if [ -n "$hit" ]; then
      IFS="$TAB" read -r _ _ _ state _ tmux att _ pid <<<"$hit"
      if [ "$force" = 0 ] && [ "$tmux" != - ]; then
        say "${sid:0:8} is still running here ($state), in tmux session '$tmux'$([ "$att" = 1 ] && echo ', attached elsewhere too')."
        say "attaching to it: a fresh resume would be a second copy, and the two would diverge."
        tmux_attach "$tmux"
      elif [ "$force" = 0 ]; then
        say "${sid:0:8} is still running here outside tmux (pid $pid), in the terminal it was started from."
        say "a second copy would diverge from it, so sj will not start one. Go back to that terminal, or"
        echo "    sj resume --force ${sid:0:8}"
        return 3
      fi
      say "--force: starting a second copy although pid $pid still runs it here. The two will diverge."
    fi
    # 2. running elsewhere (as far as the last relayed lease says)
    hit="$(remote_live "$sid" "$rows")"
    if [ -n "$hit" ]; then
      host="$(cut -f2 <<<"$hit")"
      say "${sid:0:8} was $(cut -f4 <<<"$hit") on '$host' as of $(stamp "$(cut -f5 <<<"$hit")") (a relayed snapshot)."
      if [ "$force" = 0 ]; then
        if [ "${SJ_ASSUME_TTY:-0}" = 1 ] || { [ -t 0 ] && [ -t 1 ]; }; then
          printf 'sj: [A]ttach there over ssh, [h]and it off to this machine (a second copy: the two diverge), [q]uit? ' >&2
          ans=q; read -r ans || ans=q
          case "$ans" in
            ''|a|A) remote_attach "$host" "$sid"; return 1 ;;
            h|H) say "handing it off here. The copy on '$host' keeps running and will not see these turns." ;;
            *) return 0 ;;
          esac
        else
          say "it may still be running there. Attach to it, or hand it off anyway (a second copy):"
          echo "    sj attach ${sid:0:8}"
          echo "    sj resume --force ${sid:0:8}"
          return 3
        fi
      else
        say "--force: handing it off anyway. The copy on '$host' will not see these turns."
      fi
    fi
    # 3. stopped, and its transcript is here
    proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
    t="$(sj_ls_by_mtime "$proj" "$sid.jsonl" 2 | head -n 1)"
    if [ -n "$t" ]; then
      cwd="$(sj_adapter_call claude sjh_session_cwd "$t" 2>/dev/null)"
      if [ -n "$cwd" ] && [ -d "$cwd" ]; then
        sj_has "$CLAUDE_BIN" || { say "'$CLAUDE_BIN' is not on PATH"; return 127; }
        say "${sid:0:8} is not running, and its transcript is here: resuming it in $(sj_pretty_path "$cwd")"
        say "  cd $(sj_pretty_path "$cwd") && claude --resume $sid"
        cd "$cwd" || return 1
        launch "$CLAUDE_BIN" --resume "$sid" "${rest[@]+"${rest[@]}"}"
      fi
      say "${sid:0:8}'s folder '${cwd:-?}' is not here any more: handing it over to claude resume"
    fi
  fi
  # 4. not here: the cross-machine hand-off, into the folder you are standing in
  say "${sid:-$want} is not on this machine: handing it off from the archive into $(sj_pretty_path "$PWD") (claude resume)"
  launch bash "$APP/bin/sj-claude-resume.sh" "${sid:-$want}" "${rest[@]+"${rest[@]}"}"
}

usage() { awk 'NR > 4 && /^#/ {sub(/^# ?/, ""); print; next} NR > 4 {exit}' "${BASH_SOURCE[0]}"; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  pick|p)   cmd_pick "$@" ;;
  ls|list)  cmd_ls ;;
  rows)     cmd_rows ;;
  view|v)   cmd_view "$@" ;;
  attach|a) cmd_attach "$@" ;;
  resume|r) cmd_resume "$@" ;;
  where)    cmd_where "$@" ;;
  help|-h|--help) usage ;;
  '') if [ -t 0 ] && [ -t 1 ]; then cmd_pick; fi; usage; exit 2 ;;
  -*) cmd_pick "$cmd" "$@" ;;
  *) echo "sj: unknown command '$cmd' (pick, ls, attach, resume, view, where, help)" >&2; exit 2 ;;
esac
