#!/usr/bin/env bash
# Query the rendered chat catalogue — filter rows, slice them, print them.
#
#   sj-table.sh                             summary only: counts + where the file is
#   sj-table.sh head=20                     the newest 20 sessions
#   sj-table.sh tail=10                     the oldest 10
#   sj-table.sh [50:80]                     rows 50..79, newest-first index, 0-based
#   sj-table.sh harness=opencode            every opencode session
#   sj-table.sh harness=claude host=henpi head=20
#                                           filter FIRST, then slice — the common case
#   sj-table.sh all                         the whole table, explicitly
#
#   filters: host= project= harness= model= since=YYYY-MM-DD until=YYYY-MM-DD topic=<substr>
#   slices:  head=N  tail=N  [a:b]  [a:]  [:b]  all
#   other:   --no-pull (skip the refresh)   --path (print the catalogue's path and exit)
#
# ── why this reads the rendered file rather than the logs ─────────────────────────────────────
# bin/sj-catalogue.sh already parses logs/*.log and renders the aligned table; re-deriving it here
# would mean two copies of that parse drifting apart. So this queries the artifact: the rows are
# already aligned, already newest-first, and already agree with what a human sees in the file.
# CATALOGUE.md is derived and regenerated on every SessionStart/SessionEnd, so it is current by
# construction — and if it is missing (a machine whose first session has not ended yet) this
# generates it rather than reporting an empty archive.
#
# Printing nothing by default is deliberate. The catalogue is ~600 rows; dumping it into a chat
# costs more than the MCP round-trip it exists to avoid. You ask for rows, you get rows.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh"; sj_load_config

# ── pure helpers (the suite asserts on these) ─────────────────────────────────────────────────

# A pandas-style slice, parsed into "start count" for tail/head math. Accepts [a:b], [a:], [:b].
# Empty ends mean "from the beginning" / "to the end"; a is inclusive, b exclusive, both 0-based.
sjt_parse_slice() {  # sjt_parse_slice "[a:b]" <total>  -> "<start> <count>", or non-zero
  local s="$1" total="${2:-0}" a b
  case "$s" in \[*:*\]) ;; *) return 1 ;; esac
  s="${s#[}"; s="${s%]}"
  a="${s%%:*}"; b="${s#*:}"
  case "$a" in ""|*[!0-9]*) [ -z "$a" ] || return 1 ;; esac
  case "$b" in ""|*[!0-9]*) [ -z "$b" ] || return 1 ;; esac
  [ -n "$a" ] || a=0
  [ -n "$b" ] || b="$total"
  [ "$b" -gt "$a" ] 2>/dev/null || { printf '0 0'; return 0; }
  printf '%s %s' "$a" "$((b - a))"
}

[ "${SCRUBJAY_TABLE_LIB:-0}" = 1 ] && return 0 2>/dev/null || true

# ── arguments ─────────────────────────────────────────────────────────────────────────────────

pull=1; want_path=0; mode=summary; n=0; slice=""
f_host=""; f_project=""; f_harness=""; f_model=""; f_topic=""; f_since=""; f_until=""

for arg in "$@"; do
  case "$arg" in
    --no-pull)   pull=0 ;;
    --path)      want_path=1 ;;
    -h|--help)   awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    all)         mode=all ;;
    head=*)      mode=head; n="${arg#head=}" ;;
    tail=*)      mode=tail; n="${arg#tail=}" ;;
    \[*:*\])     mode=slice; slice="$arg" ;;
    host=*)      f_host="${arg#host=}" ;;
    project=*)   f_project="${arg#project=}" ;;
    harness=*)   f_harness="${arg#harness=}" ;;
    model=*)     f_model="${arg#model=}" ;;
    topic=*)     f_topic="${arg#topic=}" ;;
    since=*)     f_since="${arg#since=}" ;;
    until=*)     f_until="${arg#until=}" ;;
    "")          ;;
    *) printf 'sj-table: unknown argument %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done
case "$mode" in
  head|tail) case "$n" in ''|*[!0-9]*) printf 'sj-table: %s= needs a number\n' "$mode" >&2; exit 2 ;; esac ;;
esac

DATA="$(sj_data)" || exit 1
CAT="$DATA/logs/CATALOGUE.md"

[ "$want_path" = 1 ] && { printf '%s\n' "$CAT"; exit 0; }

# Missing or stale? Regenerate. sj-catalogue.sh pulls unless told not to, so --no-pull rides through.
if [ ! -f "$CAT" ]; then
  if [ "$pull" = 1 ]; then "$APP/bin/sj-catalogue.sh" >/dev/null 2>&1
  else "$APP/bin/sj-catalogue.sh" --no-pull >/dev/null 2>&1; fi
fi
[ -f "$CAT" ] || { printf 'sj-table: no catalogue at %s — run bin/sj-catalogue.sh\n' "$CAT" >&2; exit 1; }

# ── select ────────────────────────────────────────────────────────────────────────────────────
# Rows are the lines starting "| YYYY-" ; the two header lines are reprinted separately so any
# slice still arrives as a readable table rather than naked pipes.
rows="$(awk -v h="$f_host" -v p="$f_project" -v hn="$f_harness" -v m="$f_model" \
            -v t="$f_topic" -v s="$f_since" -v u="$f_until" '
  BEGIN { FS = " *\\| *" }
  # Four literal [0-9], not [0-9]{4}: mawk has no interval expressions and matches NOTHING here,
  # silently — the quiet-wrong-answer class AGENTS.md warns about. Pinned in test_portability.sh.
  /^\| [0-9][0-9][0-9][0-9]-/ {
    # Dates compare lexically: "YYYY-MM-DD" sorts correctly as a string, so the bounds need no
    # date(1) — which is the portable win, GNU `date -d` and BSD `date -j` share no syntax.
    d = substr($2, 1, 10)
    if (s != "" && d <  s) next
    if (u != "" && d >  u) next
    if (h  != "" && $3 != h)  next
    if (p  != "" && index($4, p) == 0) next
    if (hn != "" && $5 != hn) next
    if (m  != "" && index($6, m) == 0) next
    if (t  != "" && index(tolower($10), tolower(t)) == 0) next
    print
  }' "$CAT")"

total="$(printf '%s' "$rows" | grep -c . 2>/dev/null)"; total="${total:-0}"

# The first two `|` lines are the header and its separator — the separator has no space after the
# pipe, so anything anchored on "| " misses it and the slice arrives without a rule under it.
header() { grep -m2 '^|' "$CAT" 2>/dev/null; }

emit() {  # emit <start> <count>
  [ "$total" -gt 0 ] || { printf 'no sessions match.\n'; return; }
  header
  printf '%s\n' "$rows" | awk -v st="$1" -v ct="$2" 'NR > st && NR <= st + ct'
}

# A filter is itself a bounded request — "the opencode sessions" is an answer, not a count — so it
# prints its rows without needing a slice. But a broad filter can still match hundreds, so it caps
# and says it capped. An unfiltered, unsliced call stays a summary: that is the one case where the
# honest answer is "~600 rows, here is the file" rather than ~600 rows.
CAP="${SCRUBJAY_TABLE_CAP:-50}"

case "$mode" in
  summary)
    if [ -n "$f_host$f_project$f_harness$f_model$f_topic$f_since$f_until" ]; then
      if [ "$total" -gt "$CAP" ]; then
        emit 0 "$CAP"
        printf '\nshowing the newest %s of %s matches — add head=N, [a:b] or all for the rest.\n' "$CAP" "$total"
      else
        emit 0 "$total"
      fi
    else
      printf '%s sessions in the catalogue\n%s\n' "$total" "$CAT"
      printf 'add head=N, tail=N, [a:b], all, or a filter (host= project= harness= since= …) to print rows.\n'
    fi
    ;;
  all)   emit 0 "$total" ;;
  head)  emit 0 "$n" ;;
  tail)  st=$(( total - n )); [ "$st" -lt 0 ] && st=0; emit "$st" "$n" ;;
  slice)
    read -r st ct <<EOF
$(sjt_parse_slice "$slice" "$total")
EOF
    [ -n "${st:-}" ] || { printf 'sj-table: bad slice %s (use [a:b], [a:] or [:b])\n' "$slice" >&2; exit 2; }
    emit "$st" "$ct"
    ;;
esac
