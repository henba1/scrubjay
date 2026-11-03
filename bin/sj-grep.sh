#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# Keyword search over archived sessions — which sessions mention these words, and where.
#
#   sj-grep.sh borg prune                    sessions mentioning borg OR prune, best first
#   sj-grep.sh --all borg prune              only sessions mentioning BOTH
#   sj-grep.sh "retention policy" host=nas   a quoted phrase is ONE literal term
#   sj-grep.sh borg since=2026-09-01 head=50 the newest 50 sessions since Sept, searched
#   sj-grep.sh 1a2b3c4d borg                 search inside one session (bare 8-hex = a session)
#   sj-grep.sh session=1a2b3c4d,5e6f7a8b -e cafebabe
#                                            -e forces a term (a keyword that looks like an id)
#
#   scope:   host= project= harness= model= topic= since=YYYY-MM-DD until=YYYY-MM-DD
#            session=<sid8|sid>[,…]  (or bare session ids)    — same vocabulary as sj-table.sh
#            head=N tail=N [a:b]     slice the scope (newest-first) BEFORE searching it
#   match:   --any (default: a session needs one term)   --all (it needs every term)
#            case-insensitive, literal (no regex). Ranked by distinct terms hit, then hit lines,
#            then recency.
#   output:  --limit=N sessions (10)  --max-snippets=N per session (3)  --context=N lines (2)
#            --json (one object per line: "type":"session" rows, then one "type":"summary")
#            --color=auto|always|never (hits are «marked» when not coloured)
#
#   exit:    0 matches   1 no matches   2 usage   3 no filesystem view of the archive here
#            (rsync-wg backend, or the archive root is missing) — search with sjmcp instead.
#
# ── why the readable layer, and why grep first ────────────────────────────────────────────────
# Every harness renders its sessions into one Markdown shape (`## User` / `## Assistant` blocks,
# bin/adapters/README.md), so searching <archive>/<host>/readable/ covers Claude, opencode and
# Codex alike and the turn numbers printed here are the ones sj_get(turns=) slices by. The raw
# transcripts are tens of MB of JSON; the readables are what a person would search.
#
# The work is shaped so nothing reads a whole transcript more often than grep must: one `grep -l`
# over the scope finds candidates, one `grep -c` per term ranks them, and only the sessions that
# get SHOWN are read again — `grep -o` for hit positions, then awk up to the last line it prints.
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 1
. "$APP/bin/lib.sh"; sj_load_config
# sjt_parse_slice — the slice grammar is sj-table.sh's, not a second copy of it.
SCRUBJAY_TABLE_LIB=1 . "$APP/bin/sj-table.sh"

die()   { printf 'sj-grep: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}"; }

# A bare argument is a session when it can only be one: an 8-hex handle, a UUID, or an opencode id.
# A keyword that happens to look like that (`deadbeef`) is passed with -e.
sjg_is_sid() {
  case "$1" in
    ses_*) [[ "$1" =~ ^ses_[0-9A-Za-z]+$ ]] ;;
    *)     [[ "$1" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$ ]] ;;
  esac
}

# Where this machine can READ the archive as files — the same roots the transports read back from
# (hooks/transports/{local,git}.sh). rsync-wg's relay key is write-only by design, so there is no
# such view there; that is exit 3, distinct, so /sjgrep knows to search via sjmcp instead.
sjg_archive_root() {
  local root
  case "${SCRUBJAY_TRANSCRIPT_BACKEND:-git}" in
    rsync-wg)
      printf 'sj-grep: no-archive: the rsync-wg relay is write-only — this machine has no filesystem view of the archive.\n' >&2
      printf '         search it through sjmcp instead (sj_recall / sj_search_within).\n' >&2
      return 3 ;;
    local) root="${SCRUBJAY_LOCAL_CHATS:-}" ;;
    git)   root="$(sj_chats)" ;;
    *)     root="${SCRUBJAY_LOCAL_CHATS:-}" ;;
  esac
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    printf "sj-grep: no-archive: archive root '%s' not found (%s backend) — NAS not mounted, or no clone?\n" \
      "$root" "${SCRUBJAY_TRANSCRIPT_BACKEND:-git}" >&2
    printf '         search it through sjmcp instead (sj_recall / sj_search_within).\n' >&2
    return 3
  fi
  printf '%s' "$root"
}

# ── arguments ─────────────────────────────────────────────────────────────────────────────────

terms=(); sessions=""; need_all=0; limit=10; max_snip=3; ctx=2; json=0; color=auto
smode=""; n=0; slice=""
f_host=""; f_project=""; f_harness=""; f_model=""; f_topic=""; f_since=""; f_until=""

num() { case "$2" in ''|*[!0-9]*) die "$1 needs a number" ;; esac; printf '%s' "$2"; }

while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --)               shift; terms+=("$@"); break ;;
    -h|--help)        usage; exit 0 ;;
    -e)               [ $# -ge 2 ] || die "-e needs a term"; terms+=("$2"); shift ;;
    --all)            need_all=1 ;;
    --any)            need_all=0 ;;
    --json)           json=1 ;;
    --limit=*)        limit="$(num --limit "${a#*=}")" || exit 2 ;;
    --max-snippets=*) max_snip="$(num --max-snippets "${a#*=}")" || exit 2 ;;
    --context=*|context=*) ctx="$(num context "${a#*=}")" || exit 2 ;;
    --limit|--max-snippets|--context)
                      [ $# -ge 2 ] || die "$a needs a number"
                      v="$(num "$a" "$2")" || exit 2; shift
                      case "$a" in --limit) limit="$v" ;; --max-snippets) max_snip="$v" ;; *) ctx="$v" ;; esac ;;
    --color=*)        color="${a#*=}"; case "$color" in auto|always|never) ;; *) die "--color is auto|always|never" ;; esac ;;
    all)              smode="" ;;
    head=*)           smode="head"; n="$(num head= "${a#head=}")" || exit 2 ;;
    tail=*)           smode="tail"; n="$(num tail= "${a#tail=}")" || exit 2 ;;
    \[*:*\])          smode="slice"; slice="$a" ;;
    host=*)           f_host="${a#host=}" ;;
    project=*)        f_project="${a#project=}" ;;
    harness=*)        f_harness="${a#harness=}" ;;
    model=*)          f_model="${a#model=}" ;;
    topic=*)          f_topic="${a#topic=}" ;;
    since=*)          f_since="${a#since=}" ;;
    until=*)          f_until="${a#until=}" ;;
    session=*|sessions=*) sessions="$sessions,${a#*=}" ;;
    "")               ;;
    -*)               die "unknown option $a (try --help)" ;;
    *=*)              die "unknown filter ${a%%=*}= (a keyword containing '=' goes after -e)" ;;
    *)                if sjg_is_sid "$a"; then sessions="$sessions,$a"; else terms+=("$a"); fi ;;
  esac
  shift
done
[ "${#terms[@]}" -gt 0 ] || die "no keywords given (try --help)"
for t in "${terms[@]}"; do [ -n "$t" ] || die "an empty keyword matches everything — drop it"; done
[ "$limit" -gt 0 ] || die "--limit must be at least 1"
if [ "$color" = auto ]; then
  if [ -t 1 ] && [ "$json" = 0 ]; then color=always; else color=never; fi
fi

ROOT="$(sjg_archive_root)" || exit 3
ROOT="${ROOT%/}"

TMP="$(mktemp -d)" || die "mktemp failed" 1
trap 'rm -rf "$TMP"' EXIT

# ── scope: every readable session, joined with what the catalogue knows about it ──────────────
# The catalogue (sj_log_catalogue: last row per session wins) supplies date, host, harness and the
# topic someone actually wrote; the readable filename supplies the rest for a session that was
# never catalogued (backfilled, or a hand-off copy under a second host). Universe rows, TSV:
#   <ts> <host> <sid> <harness> <project> <topic> <path>
for f in "$ROOT"/*/readable/*/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done > "$TMP/files"
sj_log_catalogue > "$TMP/cat" 2>/dev/null || : > "$TMP/cat"
# model= is not in the catalogue TSV, so only that filter pays for a second pass over the logs.
: > "$TMP/models"
if [ -n "$f_model" ]; then
  data="$(sj_data 2>/dev/null)" && awk -F' *\\| *' '
    { sid=""; m=""
      for (i=1; i<=NF; i++) { if ($i ~ /^session=/) sid=substr($i, 9); if ($i ~ /^model=/) m=substr($i, 7) }
      if (sid != "") model[sid]=m }
    END { for (s in model) print s "\t" model[s] }' "$data"/logs/*.log > "$TMP/models" 2>/dev/null
fi

awk -F'\t' -v OFS='\t' -v root="$ROOT" -v sess="$sessions" \
    -v fh="$f_host" -v fp="$f_project" -v fn="$f_harness" -v fm="$f_model" \
    -v ft="$f_topic" -v fs="$f_since" -v fu="$f_until" '
  function handle(s) { sub(/^ses_/, "", s); return tolower(substr(s, 1, 8)) }
  FILENAME == ARGV[1] {                                   # the readable files
    rel = substr($0, length(root) + 2); split(rel, p, "/")
    stem = p[4]; sub(/\.md$/, "", stem)
    h = stem; sub(/.*__/, "", h); h = tolower(h)
    nf++; fpath[nf] = $0; fhost[nf] = p[1]; fproj[nf] = p[3]; fh_[nf] = h
    fdate[nf] = substr(stem, 1, 10)
    t = stem; sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_/, "", t); sub(/__[^_]*$/, "", t)
    gsub(/-/, " ", t); ftopic[nf] = t
    byh[h] = byh[h] " " nf
    next
  }
  FILENAME == ARGV[2] { model[$1] = $2; havem = 1; next }  # sid -> model
  {                                                       # the catalogue: ts host sid cwd topic harness
    h = handle($3); if (!(h in byh)) { orphan[h] = $2 "\t" $3; next }
    n = split(byh[h], ids, " "); pick = ids[1]
    for (i = 1; i <= n; i++) { if (fhost[ids[i]] == $2) pick = ids[i]; used[ids[i]] = 1 }
    emit($1, $2, $3, $6, fproj[pick], $5, fpath[pick], h)
  }
  END {
    for (i = 1; i <= nf; i++) if (!(i in used) && !(fh_[i] in seen) && (seen[fh_[i]] = 1))
      emit(fdate[i], fhost[i], fh_[i], "-", fproj[i], ftopic[i], fpath[i], fh_[i])
    # a session asked for by id that has no readable copy here: say so rather than search nothing
    for (h in wanth) if (!(h in byh)) {
      if (h in orphan) { split(orphan[h], o, "\t"); printf "sj-grep: %s has no readable copy in this archive (catalogued on %s)\n", h, o[1] > "/dev/stderr" }
      else printf "sj-grep: %s is not in this archive or its catalogue\n", h > "/dev/stderr"
    }
  }
  function emit(ts, host, sid, harness, proj, topic, path, h,   d, m) {
    d = substr(ts, 1, 10)
    if (nwant && !(h in want) && !(tolower(sid) in want)) return
    if (fs != "" && d < fs) return
    if (fu != "" && d > fu) return
    if (fh != "" && host != fh) return
    if (fp != "" && index(tolower(proj), tolower(fp)) == 0) return
    if (fn != "" && harness != fn) return
    if (ft != "" && index(tolower(topic), tolower(ft)) == 0) return
    if (fm != "") { m = (sid in model) ? model[sid] : ""; if (m == "" || index(m, fm) == 0) return }
    # bash `read` collapses adjacent tabs, so an empty field would shift every one after it
    if (harness == "") harness = "-"; if (proj == "") proj = "-"; if (topic == "") topic = "-"
    print ts, host, sid, harness, proj, topic, path
  }
  BEGIN {
    nw = split(sess, w, ","); for (i = 1; i <= nw; i++) if (w[i] != "") { want[handle(w[i])] = 1; wanth[handle(w[i])] = 1; want[tolower(w[i])] = 1; nwant++ }
    # ARGV[2] may be an empty file; awk would then never see FILENAME == ARGV[2]. Harmless.
  }
' "$TMP/files" "$TMP/models" "$TMP/cat" | sort -t"$(printf '\t')" -k1,1r > "$TMP/scope"

total="$(grep -c . "$TMP/scope")"; total="${total:-0}"
case "$smode" in
  head)  head -n "$n" "$TMP/scope" > "$TMP/s2" ;;
  tail)  tail -n "$n" "$TMP/scope" > "$TMP/s2" ;;
  slice) read -r st ct <<EOF
$(sjt_parse_slice "$slice" "$total")
EOF
         [ -n "${st:-}" ] || die "bad slice $slice (use [a:b], [a:] or [:b])"
         awk -v st="$st" -v ct="$ct" 'NR > st && NR <= st + ct' "$TMP/scope" > "$TMP/s2" ;;
  *)     cp "$TMP/scope" "$TMP/s2" ;;
esac
mv "$TMP/s2" "$TMP/scope"
inscope="$(grep -c . "$TMP/scope")"; inscope="${inscope:-0}"

# ── match: one grep -l over the scope, then one grep -c per term over the candidates ──────────
eargs=(); for t in "${terms[@]}"; do eargs+=(-e "$t"); done
cut -f7 "$TMP/scope" | tr '\n' '\0' > "$TMP/paths0"
: > "$TMP/cand"
# BSD xargs runs its command once even on empty input (there is no portable -r) — and grep with
# no file would then read stdin. Only call it with something to read.
[ "$inscope" -gt 0 ] && xargs -0 grep -F -i -l "${eargs[@]}" -- < "$TMP/paths0" > "$TMP/cand" 2>/dev/null
tr '\n' '\0' < "$TMP/cand" > "$TMP/cand0"
: > "$TMP/counts"
if [ -s "$TMP/cand" ]; then
  # -H: a single candidate would otherwise come back without its filename.
  xargs -0 grep -H -F -i -c "${eargs[@]}" -- < "$TMP/cand0" 2>/dev/null | sed 's/^/0\t/' >> "$TMP/counts"
  i=0
  for t in "${terms[@]}"; do
    i=$((i + 1))
    xargs -0 grep -H -F -i -c -e "$t" -- < "$TMP/cand0" 2>/dev/null | sed "s/^/$i\t/" >> "$TMP/counts"
  done
fi

# Rank rows, TSV: <distinct> <hits> <ts> <per-term counts, comma-sep> <the scope row…>
awk -F'\t' -v OFS='\t' -v nt="${#terms[@]}" -v need_all="$need_all" '
  FILENAME == ARGV[1] {                    # "<term#>\t<path>:<count>" — split on the LAST colon
    k = $1; s = $2; c = s; sub(/.*:/, "", c); p = substr(s, 1, length(s) - length(c) - 1)
    cnt[p, k] = c + 0; next
  }
  {
    p = $7; if (!((p, 0) in cnt) || cnt[p, 0] == 0) next
    d = 0; per = ""
    for (k = 1; k <= nt; k++) { c = ((p, k) in cnt) ? cnt[p, k] : 0; if (c > 0) d++; per = per (k > 1 ? "," : "") c }
    if (need_all && d < nt) next
    print d, cnt[p, 0], $1, per, $0
  }' "$TMP/counts" "$TMP/scope" \
  | sort -t"$(printf '\t')" -k1,1nr -k2,2nr -k3,3r > "$TMP/ranked"

matched="$(grep -c . "$TMP/ranked")"; matched="${matched:-0}"
shown=$(( matched < limit ? matched : limit ))

# ── snippets: one grep -o for hit positions, then awk reads up to its last printed line ───────
# Window choice: the first hit of each distinct term first (so a 2-term match shows both terms),
# then the earliest remaining hits, until --max-snippets windows; a hit inside an existing window
# widens nothing and costs nothing, a window overlapping another merges into it.
# shellcheck disable=SC2016  # an awk program: its $ fields are awk's, not the shell's
SNIP_AWK='
function jesc(s,   i, c, o, b) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""
    else if (c == "\n") o = o "\\n"; else if (c == "\t") o = o "\\t"; else if (c == "\r") o = o "\\r"
    else if ((b = ord[c]) > 0 && b < 32) o = o sprintf("\\u%04x", b)
    else o = o c
  }
  return o
}
# Byte-wise substr can split a UTF-8 character; shave the partial sequence off either end so the
# text stays valid (a strict JSON reader rejects a broken one).
function utf8trim(s,   b, i, need) {
  while (length(s) && (b = ord[substr(s, 1, 1)]) >= 128 && b < 192) s = substr(s, 2)
  for (i = length(s); i > 0 && i > length(s) - 4; i--) {
    b = ord[substr(s, i, 1)]
    if (b < 128) break
    if (b >= 192) { need = (b >= 240) ? 4 : (b >= 224) ? 3 : 2
                    if (length(s) - i + 1 < need) s = substr(s, 1, i - 1)
                    break }
  }
  return s
}
function firstpos(lc,   k, q, best) {
  best = 0
  for (k = 1; k <= nt; k++) { q = index(lc, lt[k]); if (q && (!best || q < best)) best = q }
  return best
}
function clip(s, ishit,   q, st, w) {
  w = ishit ? 220 : 160
  if (length(s) <= w) return s
  st = 1
  if (ishit) { q = firstpos(tolower(s)); if (q > 80) st = q - 80 }
  return (st > 1 ? "…" : "") utf8trim(substr(s, st, w)) "…"
}
function mark(s,   lc, out, q, best, bk, k) {
  if (json) return s
  lc = tolower(s); out = ""
  while (1) {
    best = 0; bk = 0
    for (k = 1; k <= nt; k++) { q = index(lc, lt[k]); if (q && (!best || q < best || (q == best && length(lt[k]) > length(lt[bk])))) { best = q; bk = k } }
    if (!best) break
    out = out substr(s, 1, best - 1) HL1 substr(s, best, length(lt[bk])) HL2
    s = substr(s, best + length(lt[bk])); lc = substr(lc, best + length(lt[bk]))
  }
  return out s
}
BEGIN {
  for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
  nt = split(ENVIRON["SJG_TERMS"], t, "\037")
  for (k = 1; k <= nt; k++) lt[k] = tolower(t[k])
  json = ENVIRON["SJG_JSON"] + 0; ctx = ENVIRON["SJG_CTX"] + 0; maxs = ENVIRON["SJG_MAX"] + 0
  if (ENVIRON["SJG_COLOR"] == "always") { HL1 = "\033[1;33m"; HL2 = "\033[0m" } else { HL1 = "«"; HL2 = "»" }
}
FILENAME == ARGV[1] {                       # grep -n -o: "<line>:<matched text>"
  c = index($0, ":"); L = substr($0, 1, c - 1) + 0; m = tolower(substr($0, c + 1))
  nh++; hl[nh] = L; ishit[L] = 1
  for (k = 1; k <= nt; k++) if (m == lt[k] && !(k in firsthit)) { firsthit[k] = nh }
  next
}
FNR == 1 && !picked {
  # order candidates: the first hit per term, then every hit in line order
  nc = 0
  for (k = 1; k <= nt; k++) if (k in firsthit) cand[++nc] = hl[firsthit[k]]
  for (i = 1; i <= nh; i++) cand[++nc] = hl[i]
  nw = 0
  for (i = 1; i <= nc; i++) {
    L = cand[i]; hit = 0
    for (j = 1; j <= nw; j++) if (L >= wa[j] && L <= wb[j]) { hit = 1; break }
    if (hit) continue
    a = L - ctx; if (a < 1) a = 1; b = L + ctx
    # overlaps an existing window: merge into it — but only up to three windows of length, or one
    # dense passage (a long tool output full of the term) would swallow the whole budget
    for (j = 1; j <= nw; j++) if (a <= wb[j] + 1 && b >= wa[j] - 1) {
      hit = 1
      if ((b > wb[j] ? b : wb[j]) - (a < wa[j] ? a : wa[j]) < 3 * (2 * ctx + 1)) {
        if (a < wa[j]) wa[j] = a; if (b > wb[j]) wb[j] = b }
      break }
    if (hit) continue
    if (nw >= maxs) break
    nw++; wa[nw] = a; wb[nw] = b
  }
  # sort windows by start (few of them: insertion sort)
  for (i = 2; i <= nw; i++) { x = wa[i]; y = wb[i]; for (j = i - 1; j >= 1 && wa[j] > x; j--) { wa[j+1] = wa[j]; wb[j+1] = wb[j] } wa[j+1] = x; wb[j+1] = y }
  last = 0; for (j = 1; j <= nw; j++) if (wb[j] > last) last = wb[j]
  picked = 1; turn = 0; tturns = ""
}
{
  if (FNR <= 5 && tturns == "" && match($0, /^_[0-9]+ turns?_$/)) { tturns = substr($0, 2) + 0 }
  if ($0 ~ /^## (User|Assistant)([^A-Za-z0-9_]|$)/) turn++
  for (j = 1; j <= nw; j++) if (FNR >= wa[j] && FNR <= wb[j]) {
    if (!(j in wturn) && ishit[FNR]) { wturn[j] = turn; wline[j] = FNR }
    txt[j] = txt[j] (FNR > wa[j] ? "\n" : "") (json ? "" : sprintf("%s %5d  ", ishit[FNR] ? ">" : " ", FNR)) mark(clip($0, ishit[FNR]))
  }
  if (FNR >= last) exit
}
END {
  if (json) {
    printf "\"turns\":%s,\"snippets\":[", (tturns == "" ? "null" : tturns)
    for (j = 1; j <= nw; j++) {
      if (wb[j] > FNR) wb[j] = FNR
      printf "%s{\"turn\":%d,\"line\":%d,\"start\":%d,\"end\":%d,\"text\":\"%s\"}", (j > 1 ? "," : ""), wturn[j], wline[j], wa[j], wb[j], jesc(txt[j])
    }
    printf "]"
  } else {
    for (j = 1; j <= nw; j++) {
      if (wb[j] > FNR) wb[j] = FNR
      if (wturn[j] > 0) printf "    turn %d, line %d  (sj_get turns=%d · lines=%d-%d)\n%s\n", wturn[j], wline[j], wturn[j], wa[j], wb[j], txt[j]
      else              printf "    title, line %d  (sj_get lines=%d-%d)\n%s\n", wline[j], wa[j], wb[j], txt[j]
    }
  }
}'

# Terms travel to awk through the environment, joined on the unit separator: `awk -v` would
# interpret backslash escapes inside a keyword, ENVIRON does not.
SJG_TERMS="$(printf '%s\037' "${terms[@]}")"; SJG_TERMS="${SJG_TERMS%$'\037'}"
export SJG_TERMS SJG_JSON="$json" SJG_CTX="$ctx" SJG_MAX="$max_snip" SJG_COLOR="$color"

jstr() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"; }
quoted_terms() { local t out=""; for t in "${terms[@]}"; do out="$out${out:+, }\"$t\""; done; printf '%s' "$out"; }
if [ "$color" = always ]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; else B=""; D=""; R=""; fi

if [ "$json" = 0 ]; then
  if [ "$matched" -eq 0 ]; then
    printf 'no session in scope (%s searched) mentions %s %s.\n' "$inscope" "$([ "$need_all" = 1 ] && echo 'all of' || echo 'any of')" "$(quoted_terms)"
  else
    printf '%s of %s sessions in scope mention %s %s' "$matched" "$inscope" "$([ "$need_all" = 1 ] && echo 'all of' || echo 'any of')" "$(quoted_terms)"
    [ "$matched" -gt "$shown" ] && printf ' — showing the best %s' "$shown"
    printf '\n'
  fi
fi

hitcap=$(( max_snip * (2 * ctx + 1) + 1 ))
rank=0
while IFS=$'\t' read -r distinct hits ts per _ts host sid harness proj topic path; do
  rank=$((rank + 1)); [ "$rank" -le "$limit" ] || break
  h="$(sj_session_handle "${sid#ses_}")"
  date="${ts:0:10}"
  # Per term, and only as many hit lines as the windows could use (-m): a common word can hit a
  # long transcript tens of thousands of times, and only the first few per term get shown.
  for t in "${terms[@]}"; do grep -n -o -i -F -m "$hitcap" -e "$t" -- "$path" 2>/dev/null; done \
    | sort -t: -k1,1n > "$TMP/hits"
  if [ "$json" = 1 ]; then
    printf '{"type":"session","rank":%d,"sid":%s,"sid8":%s,"harness":%s,"host":%s,"project":%s,"date":%s,"ts":%s,"topic":%s,"path":%s,"hits":%d,"terms_hit":%d,"term_hits":{' \
      "$rank" "$(jstr "$sid")" "$(jstr "$h")" "$(jstr "$harness")" "$(jstr "$host")" "$(jstr "$proj")" \
      "$(jstr "$date")" "$(jstr "$ts")" "$(jstr "$topic")" "$(jstr "$path")" "$hits" "$distinct"
    i=0; IFS=, read -r -a pc <<< "$per"
    for t in "${terms[@]}"; do printf '%s%s:%d' "$([ "$i" -gt 0 ] && echo ,)" "$(jstr "$t")" "${pc[$i]:-0}"; i=$((i + 1)); done
    printf '},'
    LC_ALL=C awk "$SNIP_AWK" "$TMP/hits" "$path"
    printf '}\n'
  else
    i=0; IFS=, read -r -a pc <<< "$per"; tb=""
    for t in "${terms[@]}"; do [ "${pc[$i]:-0}" -gt 0 ] && tb="$tb${tb:+, }$t ${pc[$i]}"; i=$((i + 1)); done
    printf '\n%s[%d] %s%s · %s · %s · %s · %s · %s\n' "$B" "$rank" "$h" "$R" "$harness" "$host" "$proj" "$date" "$topic"
    printf '    %s%s hit line%s, %s/%s terms (%s)%s\n' "$D" "$hits" "$([ "$hits" = 1 ] || echo s)" "$distinct" "${#terms[@]}" "$tb" "$R"
    LC_ALL=C awk "$SNIP_AWK" "$TMP/hits" "$path"
  fi
done < "$TMP/ranked"

if [ "$json" = 1 ]; then
  printf '{"type":"summary","terms":['
  i=0; for t in "${terms[@]}"; do printf '%s%s' "$([ "$i" -gt 0 ] && echo ,)" "$(jstr "$t")"; i=$((i + 1)); done
  printf '],"mode":"%s","in_scope":%d,"matched":%d,"shown":%d,"capped":%s,"archive":%s}\n' \
    "$([ "$need_all" = 1 ] && echo all || echo any)" "$inscope" "$matched" "$shown" \
    "$([ "$matched" -gt "$shown" ] && echo true || echo false)" "$(jstr "$ROOT")"
elif [ "$matched" -gt "$shown" ]; then
  printf '\n%s more matching session%s not shown — raise --limit or narrow the scope (host= since= head=…).\n' \
    "$((matched - shown))" "$([ $((matched - shown)) = 1 ] || echo s)"
fi

[ "$matched" -gt 0 ] || exit 1
exit 0
