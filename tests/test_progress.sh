#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Run progress (bin/lib.sh: sj_step / sj_progress_render) is how /sjlog and /sjsync say what they
# did, and the file the Claude Code mod follows live. Three contracts: a step that never reported
# back is rendered as skipped, never as a success; the hook path stays silent (its stdout is the
# session's context); and the TSV shape the mod parses holds.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
export SCRUBJAY_NOSHIP=1 SCRUBJAY_SYNC_NOPULL=1 SCRUBJAY_RUN_DIR="$SANDBOX/run"
. "$APP/bin/lib.sh"

section "no SCRUBJAY_PROGRESS: every call is a no-op"
( unset SCRUBJAY_PROGRESS; sj_step data ok "x"; sj_progress_end )
assert_no_file "nothing written without a run" "$SANDBOX/run/sync.tsv"
assert_eq "render prints nothing without a run" "" "$(unset SCRUBJAY_PROGRESS; sj_progress_render)"

section "render: last state wins, unreported steps are skipped, failures marked"
(
  sj_progress_begin demo "abc12345"
  sj_step alpha run; sj_step beta run; sj_step gamma run
  sj_step alpha ok "done"; sj_step beta fail "boom"
  sj_step weird ok "tab	and
newline"
  sj_progress_end
)
f="$SANDBOX/run/demo.tsv"
assert_file "the run's file is named after its op" "$f"
assert_eq "every line has four tab-separated fields" "0" \
  "$(awk -F'\t' 'NF != 4' "$f" | wc -l | tr -d ' ')"
out="$(sj_progress_render "$f")"
assert_contains "header names op and label" "$out" "scrubjay demo · abc12345 · "
assert_contains "ok step" "$out" "✓ alpha  done"
assert_contains "failed step" "$out" "✗ beta   boom"
assert_contains "a step still running at #end is skipped, not ok" "$out" "– gamma  did not report"
assert_contains "tabs and newlines in a detail are flattened" "$out" "weird  tab and newline"

section "SessionEnd with progress on: each step reports"
proj="$HOME/.claude/projects/-home-user-widget-api"; mkdir -p "$proj"
sid="66666666-2222-4333-8444-555555555555"
cp "$FIXTURES/claude-session.jsonl" "$proj/$sid.jsonl"
(
  sj_progress_begin publish "${sid:0:8}"
  printf '{"session_id":"%s","cwd":"/home/user/widget-api","transcript_path":"%s"}' \
    "$sid" "$proj/$sid.jsonl" | SCRUBJAY_HARNESS=claude bash "$APP/hooks/log-session.sh" --detached
  sj_progress_end
)
out="$(sj_progress_render "$SANDBOX/run/publish.tsv")"
assert_contains "catalogue row reported" "$out" "✓ catalogue  row for 66666666"
assert_contains "relay skip says why" "$out" "– relay      disabled (SCRUBJAY_NOSHIP)"
assert_contains "git-less data repo is a skip" "$out" "– data       git disabled"
assert_contains "unconfigured memory never claims success" "$out" "– memory     did not report"

section "SessionStart: silent on the hook path, a report with --report"
hook_out="$(bash "$APP/hooks/sync-session.sh" </dev/null 2>/dev/null)"
case "$hook_out" in *"scrubjay sync"*) _no "hook path prints no report" "got: $hook_out" ;;
  *) _ok "hook path prints no report" ;; esac
rep="$(bash "$APP/hooks/sync-session.sh" --report </dev/null 2>/dev/null)"
assert_contains "--report prints the header" "$rep" "scrubjay sync · "
assert_contains "--report lists the config step" "$rep" "config"

finish
