#!/usr/bin/env bash
# bin/sj-paste.sh — clipboard into the project's asset folder.
#
# A real clipboard needs a display, which CI and a headless Pi both lack, so the provider is a seam:
# SJ_PASTE_FAKE points at a directory of offered types + their bytes. Everything above that seam —
# type choice, naming, file-vs-text, where it lands — is tested for real.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

PASTE="$APP/bin/sj-paste.sh"
export SCRUBJAY_ASSETS="$SANDBOX/assets"

# a fake clipboard: <dir>/types lists MIME types, <dir>/<type with / as _> holds the bytes
clip() {  # clip <type> <content>  [more type/content pairs]
  local d="$SANDBOX/clip"; rm -rf "$d"; mkdir -p "$d"; : > "$d/types"
  while [ $# -gt 0 ]; do
    printf '%s\n' "$1" >> "$d/types"
    printf '%s' "$2" > "$d/$(printf '%s' "$1" | tr '/' '_')"
    shift 2
  done
  printf '%s' "$d"
}
paste_now() { SJ_PASTE_FAKE="$1" bash "$PASTE" "${@:2}"; }

section "pure helpers"
. "$APP/bin/lib.sh"; SCRUBJAY_PASTE_LIB=1 . "$APP/bin/sj-paste.sh"
assert_eq "png type maps to png"        "png" "$(sjp_ext_for_type image/png)"
assert_eq "an unknown type is not guessed" "bin" "$(sjp_ext_for_type application/x-weird)"
assert_eq "a name with slashes cannot escape the dir" "_etc_passwd" "$(sjp_safe_name '/etc/passwd')"
assert_eq "leading dots are stripped"   "bashrc" "$(sjp_safe_name '...bashrc')"
assert_eq "an empty name still yields something" "clip" "$(sjp_safe_name '')"
assert_eq "spaces become dashes"        "my-shot" "$(sjp_safe_name 'my  shot')"
assert_eq "uri decodes to a path"       "/tmp/a b.png" "$(sjp_uri_to_path 'file:///tmp/a%20b.png')"
# The one that matters: a screenshot offers BOTH image/png and a text fallback.
assert_eq "richest offered type wins over the text fallback" \
  "image/png" "$(printf 'text/plain\nimage/png\n' | sjp_best_type)"

section "an image on the clipboard becomes a .png"
d="$(clip image/png "$(printf '\x89PNG\r\n\x1a\nfake')" text/plain 'screenshot.png')"
out="$(paste_now "$d" 2>/dev/null)"
assert_contains "named and placed under the project slug" "$out" "$SCRUBJAY_ASSETS/"
case "$out" in *.png) _ok "extension came from the content type" ;; *) _no "extension came from the content type" "got $out" ;; esac
check "the file exists and is non-empty" test -s "$out"
assert_eq "written 600 — assets can be anything" "600" "$(stat -c%a "$out" 2>/dev/null || stat -f%Lp "$out")"

section "--name is honoured, and cannot escape the asset dir"
out="$(paste_now "$d" --name '../../etc/passwd' 2>/dev/null)"
assert_contains "traversal is neutralised" "$out" "$SCRUBJAY_ASSETS/"
case "$out" in *../*) _no "no .. survives in the path" "got $out" ;; *) _ok "no .. survives in the path" ;; esac

section "a copied FILE is copied, not saved as text about a file"
src="$SANDBOX/real-asset.pdf"; printf '%%PDF-1.4 body' > "$src"
d="$(clip text/uri-list "file://$src")"
out="$(paste_now "$d" 2>/dev/null)"
case "$out" in *.pdf) _ok "keeps the real extension" ;; *) _no "keeps the real extension" "got $out" ;; esac
assert_eq "content is the file itself" "$(cat "$src")" "$(cat "$out")"
# Some apps put a bare path on the clipboard as text/plain instead of a uri-list.
d="$(clip text/plain "$src")"
out="$(paste_now "$d" 2>/dev/null)"
assert_eq "a bare path is treated the same way" "$(cat "$src")" "$(cat "$out")"

section "plain text is saved as text"
d="$(clip text/plain 'just some notes')"
out="$(paste_now "$d" 2>/dev/null)"
case "$out" in *.txt) _ok "saved as .txt" ;; *) _no "saved as .txt" "got $out" ;; esac
assert_eq "content preserved" "just some notes" "$(cat "$out")"

section "it refuses rather than writing an empty file"
d="$(clip)"                       # clipboard offering nothing
check_fails "an empty clipboard is an error" bash -c 'SJ_PASTE_FAKE="$1" bash "$2"' _ "$d" "$PASTE"
check_fails "empty stdin is an error" bash -c 'printf "" | bash "$1" -' _ "$PASTE"

section "stdin sniffs the format so the extension is right"
out="$(printf '\x89PNG\r\n\x1a\nbody' | bash "$PASTE" - 2>/dev/null)"
case "$out" in *.png) _ok "a piped PNG lands as .png" ;; *) _no "a piped PNG lands as .png" "got $out" ;; esac

section "housekeeping verbs"
assert_contains "--dir names the project's folder" "$(bash "$PASTE" --dir)" "$SCRUBJAY_ASSETS/"
check "--list works even before anything is pasted" bash -c 'SCRUBJAY_ASSETS="$1/none" bash "$2" --list' _ "$SANDBOX" "$PASTE"
check_fails "an unknown flag is refused" bash "$PASTE" --nope

finish
