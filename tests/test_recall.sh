#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# sjmcp recall: ranking, snippet selection, and the "look on <host>" pointer errors.
#
# The archive here is a fixture built to reproduce two specific ranking defects (#53) rather
# than to look realistic:
#   A  a BROAD session that mentions every query term, three times each, scattered far apart
#   B  a FOCUSED session where the same terms co-occur in ONE passage, once each
# A repeats terms more densely, so the old `len(terms)*10 + n` score put A on top even though B
# is the session that actually answers the query. Same shape for a log-only catalogue pointer vs.
# a body-only transcript at equal term coverage.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v python3 >/dev/null 2>&1; then
  skip "sjmcp recall" "python3 not installed"; finish; exit
fi

sj_sandbox
mkdir -p "$SCRUBJAY_MEMORY"

# ── the driver ─────────────────────────────────────────────────────────────────────────────────
# Load mcp/sjmcp_server.py by path (the repo's mcp/ dir would otherwise shadow the pip `mcp`
# package) and evaluate one core_* call against the sandbox archive.
sjq() {  # sjq <python-expr> [jq-filter]
  python3 -c '
import importlib.util, json, os, sys
p = os.path.join(os.environ["APP"], "mcp", "sjmcp_server.py")
spec = importlib.util.spec_from_file_location("sjmcp_server", p)
m = importlib.util.module_from_spec(spec)
sys.modules["sjmcp_server"] = m          # dataclasses resolves annotations via sys.modules
spec.loader.exec_module(m)
sys.stdout.write(json.dumps(eval(sys.argv[1], {"m": m}), default=str))
' "$1" | jq -r "${2:-.}"
}

# Every assertion below reads a driver result; an empty one would pass a `contains ""` check
# vacuously, so refuse to keep going.
require_json() {  # require_json <name> <json>
  case "$2" in
    ""|null) _no "$1" "the sjmcp driver returned nothing (see the traceback above)"; finish; exit 1 ;;
  esac
}

# ── the fixture archive ────────────────────────────────────────────────────────────────────────
READ="$SCRUBJAY_LOCAL_CHATS/laptop/readable"
mkdir -p "$READ/monitor" "$READ/research" "$SCRUBJAY_DATA/logs"

filler() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "  padding line, nothing to see ($i)"; done; }

# A — broad: every term, three times, ~16 lines apart, never two terms in one passage.
{
  echo "# building the monitoring stack"
  echo "_40 turns_"
  for _round in 1 2 3; do
    for t in fixed systemd nftables error scrubjay-rx alerted ntfy; do
      echo "## Assistant"
      echo "one mention of $t, in passing."
      filler 14
    done
  done
} > "$READ/monitor/2026-07-01_building-the-monitoring-stack__aaaaaaaa.md"

# B — focused: the same seven terms, once each, inside one three-line passage.
{
  echo "# nightly alert triage"
  echo "_12 turns_"
  filler 16
  echo "## Assistant"
  echo "Root cause: the systemd unit for nftables failed to start on scrubjay-rx."
  echo "ntfy alerted me at 03:12 with the error text below."
  echo "Fixed by reloading the ruleset; the alert cleared."
  filler 30
} > "$READ/monitor/2026-07-20_nightly-alert-triage__bbbbbbbb.md"

# E — body-only, two terms scattered: the counterweight for the log-weighting check.
{
  echo "# adversarial robustness reading"
  for _round in 1 2 3; do
    for t in foolbox attack; do
      echo "a paragraph mentioning $t, in passing."
      filler 14
    done
  done
} > "$READ/research/2026-06-10_adversarial-robustness-reading__eeeeeeee.md"

# A transcript whose handle is NOT hex — an opencode/codex-shaped sid8 (#67, adjacent note).
printf '# opencode session\n\nnothing much happened here.\n' \
  > "$READ/research/2026-06-11_opencode-session__A1b2C3d4.md"

# The catalogue: A and B have transcripts here; cccccccc does not (it lives on another machine).
cat > "$SCRUBJAY_DATA/logs/laptop.log" <<'LOG'
2026-07-01 09:00 | laptop | /home/user/monitor | "building the monitoring stack with systemd and ntfy" | session=aaaaaaaa-1111-4111-8111-111111111111 | harness=claude | model=claude-sonnet-5 | turns=40 | size=120K
2026-07-20 22:10 | laptop | /home/user/monitor | "fixed systemd nftables error on scrubjay-rx alerted by ntfy" | session=bbbbbbbb-2222-4222-8222-222222222222 | harness=claude | model=claude-sonnet-5 | turns=12 | size=40K
LOG
cat > "$SCRUBJAY_DATA/logs/archive-host.log" <<'LOG'
2026-06-02 11:00 | archive-host | /home/user/research | "foolbox attack notes" | session=cccccccc-3333-4333-8333-333333333333 | harness=claude | model=claude-sonnet-5 | turns=9 | size=20K
LOG

Q='fixed systemd nftables error on scrubjay-rx alerted by ntfy'

# ── #53: the focused session must outrank the broad one ────────────────────────────────────────
section "recall ranking (#53)"

rec="$(sjq "m.core_recall('$Q', k=8)")"
require_json "recall returns JSON" "$rec"
assert_eq "the focused session ranks first, not the term-dense broad one" \
  "bbbbbbbb" "$(printf '%s' "$rec" | jq -r '.results[0].sid // ""')"
assert_contains "the broad session is still returned (prefilter, not a filter)" \
  "$(printf '%s' "$rec" | jq -r '[.results[].sid] | join(",")')" "aaaaaaaa"

b_score="$(printf '%s' "$rec" | jq -r '.results[] | select(.sid=="bbbbbbbb") | .score')"
a_score="$(printf '%s' "$rec" | jq -r '.results[] | select(.sid=="aaaaaaaa") | .score')"
if [ "${b_score:-0}" -gt "${a_score:-0}" ]; then
  _ok "co-occurrence in one passage outscores scattered repetition ($b_score > $a_score)"
else
  _no "co-occurrence in one passage outscores scattered repetition" "focused: $b_score  broad: $a_score"
fi

# ── #53 (comment): snippets are deduped and spread across the file ─────────────────────────────
section "snippet selection (#53)"

b_lines='[.results[] | select(.sid=="bbbbbbbb") | .snippets[].line | select(. != null)]'
assert_eq "a line matching several terms claims one snippet slot, not one per term" \
  "$(printf '%s' "$rec" | jq -r "$b_lines | unique | length")" \
  "$(printf '%s' "$rec" | jq -r "$b_lines | length")"

gap="$(printf '%s' "$rec" | jq -r '
  [.results[] | select(.sid=="aaaaaaaa") | .snippets[].line | select(. != null)]
  | . as $l | [range(1; ($l|length))] | map($l[.] - $l[.-1]) | min // 999')"
if [ "${gap:-0}" -ge 20 ]; then
  _ok "snippets are drawn from distinct regions of the file (min gap ${gap} lines)"
else
  _no "snippets are drawn from distinct regions of the file" "min line gap: $gap (want >= 20)"
fi

# ── #51: a snippet's line number is a line number in the file sj_get reads ─────────────────────
section "snippet line ↔ sj_get(lines=) (#51)"

snip_line="$(printf '%s' "$rec" | jq -r '.results[] | select(.sid=="bbbbbbbb") | [.snippets[].line | select(. != null)][0]')"
snip_text="$(printf '%s' "$rec" | jq -r --arg l "$snip_line" '.results[] | select(.sid=="bbbbbbbb") | .snippets[] | select(.line == ($l|tonumber)) | .text')"
got="$(sjq "m.core_get('bbbbbbbb', lines='$snip_line-$snip_line')" '.content')"
require_json "sj_get returns content" "$got"
require_json "the snippet carries text" "$snip_text"
assert_contains "sj_get(lines=<snippet.line>) returns that exact line" "$got" "$snip_text"
assert_eq "the catalogue one-liner is offered as a snippet, marked as such" \
  "2" "$(printf '%s' "$rec" | jq -r '[.results[].snippets[] | select(.source=="log")] | length')"
assert_eq "log-sourced snippets carry no line (they are not lines in .path)" \
  "0" "$(printf '%s' "$rec" | jq -r '[.results[].snippets[] | select(.source=="log") | select(has("line"))] | length')"

# ── #53: a human-written catalogue line beats an equal-coverage body match ─────────────────────
section "log-sourced hits weigh more (#53)"

rec2="$(sjq "m.core_recall('foolbox attack', k=8)")"
require_json "recall returns JSON" "$rec2"
assert_eq "the catalogue pointer outranks the equal-coverage body match" \
  "log" "$(printf '%s' "$rec2" | jq -r '.results[0].type')"
assert_eq "…and it names the host to look on" \
  "archive-host" "$(printf '%s' "$rec2" | jq -r '.results[0].host')"
assert_contains "…with the same wording the other tools use" \
  "$(printf '%s' "$rec2" | jq -r '.results[0].note')" "recall it on archive-host"

# ── #67: a catalogue-known sid is a pointer, not a typo ────────────────────────────────────────
section "catalogue-known sid → 'look on <host>' (#67)"

for call in "m.core_search_within('cccccccc', 'smart')" "m.core_get('cccccccc')"; do
  out="$(sjq "$call")"
  require_json "$call returns JSON" "$out"
  name="${call%%(*}"
  assert_contains "$name says the transcript is not here, not that the id is wrong" \
    "$(printf '%s' "$out" | jq -r '.error')" "no transcript in this archive"
  assert_eq "$name carries the host to look on" \
    "archive-host" "$(printf '%s' "$out" | jq -r '.host // ""')"
  assert_contains "$name carries the catalogue row (date/topic/cwd)" \
    "$(printf '%s' "$out" | jq -r '"\(.date)|\(.topic)|\(.cwd)"')" "2026-06-02|foolbox attack notes|"
done

unknown="$(sjq "m.core_get('deadbeef')")"
require_json "core_get returns JSON" "$unknown"
assert_contains "an id the catalogue has never seen still reads as not-found" \
  "$(printf '%s' "$unknown" | jq -r '.error')" "not found or outside the archive"
assert_eq "…and carries no host pointer" "" "$(printf '%s' "$unknown" | jq -r '.host // ""')"

# ── #67 (adjacent): a non-hex sid8 resolves by bare id ─────────────────────────────────────────
section "sid8 resolution"

assert_contains "a base62 (opencode-shaped) handle resolves like a hex one" \
  "$(sjq "m.core_get('A1b2C3d4')" '.content // .error')" "nothing much happened"
assert_contains "a bare hex sid still resolves" \
  "$(sjq "m.core_get('bbbbbbbb')" '.path // .error')" "nightly-alert-triage"

# ── regression: search_within on a transcript that IS here ─────────────────────────────────────
section "search_within"

sw="$(sjq "m.core_search_within('bbbbbbbb', 'nftables', context=1)")"
require_json "search_within returns JSON" "$sw"
assert_eq "a literal substring match reports its passages" "1" "$(printf '%s' "$sw" | jq -r '.matches')"
assert_contains "…anchored to a line and a turn" "$(printf '%s' "$sw" | jq -r '.passages[0] | "\(.line)/\(.turn)"')" "/1"

rm -rf "$SANDBOX"
finish
