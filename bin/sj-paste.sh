#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
# Put whatever is on the clipboard into this project's asset folder, and print the path.
#
# The gap it fills: if a file is already on this machine you just type its path — but a screenshot,
# a diagram or a PDF you copied is *not* a file yet, and a terminal has nowhere to paste it. This
# turns the clipboard into a path you can hand to an agent.
#
#   bin/sj-paste.sh                    paste the clipboard into the current project
#   bin/sj-paste.sh --name diagram     name it (extension comes from the content type)
#   bin/sj-paste.sh -                  read stdin instead of the clipboard  (cat x.png | sj-paste -)
#   bin/sj-paste.sh --dir              print this project's asset dir and exit
#   bin/sj-paste.sh --list             list recent assets for this project
#
# Assets are **machine-local** — $SCRUBJAY_ASSETS (default ~/.scrubjay/assets), keyed by the same
# project slug the archive and memory use. They deliberately do NOT ride the session relay:
# transcripts are small append-only records, assets are arbitrary binaries with different size,
# retention and privacy profiles, and syncing them everywhere by default would widen exposure
# nobody asked for. Anything you want kept goes in your project or the archive by hand.
#
# Clipboard providers: wl-clipboard (Wayland) and xclip/xsel (X11) are the tested paths; pbpaste
# (+pngpaste for images) on macOS and Get-Clipboard on WSL are best-effort. Over SSH there is no
# clipboard at all — it says so rather than writing an empty file.
#
# Sourcing with SCRUBJAY_PASTE_LIB=1 defines the functions without running (the tested seam).
set -uo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

# UI on stderr so stdout carries ONLY the path — `f=$(sj-paste.sh)` has to be usable.
info() { printf '\033[1;34m›\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── pure helpers (no clipboard, no filesystem — the tested seam) ───────────────────────────────

sjp_ext_for_type() {  # sjp_ext_for_type <mime>  -> file extension, no dot
  case "$1" in
    image/png)                 printf 'png' ;;
    image/jpeg|image/jpg)      printf 'jpg' ;;
    image/gif)                 printf 'gif' ;;
    image/webp)                printf 'webp' ;;
    image/svg+xml)             printf 'svg' ;;
    application/pdf)           printf 'pdf' ;;
    text/html)                 printf 'html' ;;
    text/markdown)             printf 'md' ;;
    text/plain*|STRING|UTF8_STRING) printf 'txt' ;;
    *) printf 'bin' ;;
  esac
}

# Which of the offered types we actually want. Richest first: a screenshot offers image/png AND a
# text/plain fallback, and taking the text would silently save the wrong thing.
sjp_best_type() {  # sjp_best_type  (types on stdin, one per line)
  local types; types="$(cat)"
  local want
  for want in image/png image/jpeg image/webp image/gif image/svg+xml application/pdf \
              text/uri-list text/markdown text/html text/plain UTF8_STRING STRING; do
    printf '%s\n' "$types" | grep -qx -- "$want" && { printf '%s' "$want"; return 0; }
  done
  # Nothing recognised: fall back to the first offered type rather than refusing outright.
  printf '%s\n' "$types" | grep -v '^$' | head -1 | tr -d '\n'
}

# A name safe to put in a path: no separators, no leading dashes or dots, never empty.
sjp_safe_name() {  # sjp_safe_name <raw>
  local n; n="$(printf '%s' "${1:-}" | tr '/\\' '__' | tr -cd 'A-Za-z0-9._ -' \
                 | sed -e 's/^[.-]*//' -e 's/[[:space:]]\{1,\}/-/g' -e 's/-\{2,\}/-/g' -e 's/[.-]*$//')"
  [ -n "$n" ] || n=clip
  printf '%.60s' "$n"
}

sjp_filename() {  # sjp_filename <name> <ext> [stamp]
  printf '%s-%s.%s' "${3:-$(date +%Y-%m-%d-%H%M%S)}" "$(sjp_safe_name "$1")" "$2"
}

# file:///home/u/a%20b.png  ->  /home/u/a b.png   (first entry only)
sjp_uri_to_path() {  # sjp_uri_to_path <uri-list>
  local u; u="$(printf '%s' "$1" | tr -d '\r' | grep -v '^#' | head -1)"
  case "$u" in file://*) u="${u#file://}" ;; esac
  printf '%b' "$(printf '%s' "$u" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

# ── clipboard providers ───────────────────────────────────────────────────────────────────────
# `fake` exists so the whole path above can be tested without a display: point SJ_PASTE_FAKE at a
# dir holding `types` (one MIME per line) and one file per type named after it with / -> _.
sjp_provider() {
  [ -n "${SJ_PASTE_FAKE:-}" ] && { printf 'fake'; return 0; }
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then printf 'wl'
  elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1;        then printf 'xclip'
  elif [ -n "${DISPLAY:-}" ] && command -v xsel  >/dev/null 2>&1;        then printf 'xsel'
  elif command -v pbpaste >/dev/null 2>&1;                               then printf 'pb'
  elif command -v powershell.exe >/dev/null 2>&1;                        then printf 'wsl'
  else printf 'none'; fi
}

sjp_types() {  # sjp_types <provider>
  case "$1" in
    fake)  cat "$SJ_PASTE_FAKE/types" 2>/dev/null ;;
    wl)    wl-paste --list-types 2>/dev/null ;;
    xclip) xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep '/' ;;
    xsel)  printf 'text/plain\n' ;;                       # xsel is text-only
    pb)    command -v pngpaste >/dev/null 2>&1 && printf 'image/png\n'; printf 'text/plain\n' ;;
    wsl)   printf 'text/plain\n' ;;
  esac
}

sjp_read() {  # sjp_read <provider> <type>   -> bytes on stdout
  case "$1" in
    fake)  cat "$SJ_PASTE_FAKE/$(printf '%s' "$2" | tr '/' '_')" 2>/dev/null ;;
    wl)    wl-paste --no-newline --type "$2" 2>/dev/null ;;
    xclip) xclip -selection clipboard -t "$2" -o 2>/dev/null ;;
    xsel)  xsel --clipboard --output 2>/dev/null ;;
    pb)    case "$2" in image/png) pngpaste - 2>/dev/null ;; *) pbpaste 2>/dev/null ;; esac ;;
    wsl)   powershell.exe -NoProfile -Command Get-Clipboard 2>/dev/null | tr -d '\r' ;;
  esac
}

[ "${SCRUBJAY_PASTE_LIB:-0}" = 1 ] && return 0 2>/dev/null || true

# ── main ──────────────────────────────────────────────────────────────────────────────────────
NAME=""; FROM_STDIN=0; ACTION="paste"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift ;;
    -)      FROM_STDIN=1 ;;
    --dir)  ACTION="dir" ;;
    --list) ACTION="list" ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

slug="$(sj_adapter_call "$(sj_harness)" sjh_slug "$PWD" 2>/dev/null)"
[ -n "$slug" ] || slug="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9-]/-/g')"
DIR="${SCRUBJAY_ASSETS:-$HOME/.scrubjay/assets}/$slug"

case "$ACTION" in
  dir)  printf '%s\n' "$DIR"; exit 0 ;;
  list) [ -d "$DIR" ] || { info "no assets yet for this project"; exit 0; }
        sj_ls_by_mtime "$DIR" '*' 1 2>/dev/null | head -20; exit 0 ;;
esac

mkdir -p "$DIR" 2>/dev/null || die "cannot create $DIR"
tmp="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$tmp"' EXIT

if [ "$FROM_STDIN" = 1 ]; then
  cat > "$tmp"; type="application/octet-stream"
  [ -s "$tmp" ] || die "nothing on stdin"
  # Sniff the two cases that matter, so `cat shot.png | sj-paste -` gets a .png not a .bin.
  case "$(head -c4 "$tmp" | od -An -tx1 | tr -d ' \n')" in
    89504e47) type=image/png ;; ffd8ff*) type=image/jpeg ;; 25504446) type=application/pdf ;;
    *) grep -qIm1 . "$tmp" 2>/dev/null && type=text/plain ;;
  esac
else
  prov="$(sjp_provider)"
  [ "$prov" != none ] && ! [ "$prov" = fake ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] \
    && case "$prov" in wl|xclip|xsel) prov=none ;; esac
  [ "$prov" = none ] && die "no clipboard here (headless or over SSH?). Pipe a file instead:  cat file | $(basename "$0") -"
  types="$(sjp_types "$prov")"
  [ -n "$types" ] || die "clipboard is empty"
  type="$(printf '%s\n' "$types" | sjp_best_type)"
  sjp_read "$prov" "$type" > "$tmp"
  [ -s "$tmp" ] || die "clipboard is empty (offered '$type' but returned nothing)"
fi

# A copied FILE arrives as a uri-list (or, from some apps, a plain path) — copy the real file
# rather than saving a text file containing its name.
src=""
case "$type" in
  text/uri-list) src="$(sjp_uri_to_path "$(cat "$tmp")")" ;;
  text/plain*|STRING|UTF8_STRING)
    cand="$(head -c 4096 "$tmp" | head -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -f "$cand" ] && src="$cand" ;;
esac
if [ -n "$src" ] && [ -f "$src" ]; then
  ext="${src##*.}"; [ "$ext" = "$src" ] && ext=bin
  out="$DIR/$(sjp_filename "${NAME:-$(basename "${src%.*}")}" "$ext")"
  cp -- "$src" "$out" || die "could not copy $src"
else
  out="$DIR/$(sjp_filename "${NAME:-clip}" "$(sjp_ext_for_type "$type")")"
  cp -- "$tmp" "$out" || die "could not write $out"
fi
chmod 600 "$out" 2>/dev/null || true      # assets can be anything; don't widen by default

bytes="$(sj_size "$out" 2>/dev/null || echo 0)"
ok "$type · $((bytes / 1024)) KiB"
[ "$bytes" -gt 26214400 ] && info "that is >25 MiB — assets are machine-local and never pruned automatically"
printf '%s\n' "$out"
