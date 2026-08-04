#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik. See LICENSE.

# The licence seam. scrubjay was MIT until v0.2.0-mit and is FSL-1.1-ALv2 after it, so "which terms
# does this file ship under?" now has two possible answers and no longer answers itself. A per-file
# SPDX header is what makes the current answer travel with the code — into a fork, a vendored copy,
# or a scanner — instead of living only in LICENSE, which is exactly the file a copier drops.
#
# This test exists because that header is the kind of thing that is added once and then quietly
# forgotten on every file added afterwards. A missing header is not a broken build, so nothing else
# would ever notice.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SPDX_ID="FSL-1.1-ALv2"
HEADER_LINES=10   # far enough down to clear a shebang and PEP 723 metadata, no further

# Source files only. Markdown, JSON and the skeleton are deliberately out of scope: JSON cannot
# carry a comment, docs are covered by LICENSE at the repo root, and skeleton/ is seed content that
# becomes the *user's* private data repo — stamping our licence on their config would be wrong.
list_sources() {
  if git -C "$APP" rev-parse --git-dir >/dev/null 2>&1; then
    # --others as well as --cached: a file an agent just wrote is not staged yet, and catching it
    # now is the whole point. --exclude-standard keeps .gitignore'd scratch files out.
    git -C "$APP" ls-files --cached --others --exclude-standard '*.sh' '*.py' '*.js'
  else
    # A tarball export still deserves the check; mirror the ls-files exclusions by hand.
    (cd "$APP" && find . -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' \) \
      -not -path './.git/*' -not -path './skeleton/*' | sed 's|^\./||')
  fi
}

section "every source file carries the SPDX licence header"

missing=()
total=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in skeleton/*) continue ;; esac
  [ -f "$APP/$f" ] || continue
  total=$((total + 1))
  head -n "$HEADER_LINES" "$APP/$f" | grep -q "SPDX-License-Identifier: $SPDX_ID" || missing+=("$f")
done <<< "$(list_sources)"

if [ "$total" -eq 0 ]; then
  skip "source files carry SPDX-License-Identifier: $SPDX_ID" "no source files found"
else
  # Empty expected vs. the offenders, so a failure names the files to fix rather than a exit code.
  assert_eq "all $total source files carry SPDX-License-Identifier: $SPDX_ID" \
    "" "${missing[*]-}"
fi

# The header states a licence; if it disagrees with LICENSE, the header is the one people will
# believe, because it is the one that gets copied. Pin them together.
section "the header agrees with LICENSE"

check "LICENSE declares $SPDX_ID" grep -q "^$SPDX_ID$" "$APP/LICENSE"
assert_file "the MIT period is preserved at LICENSE-MIT" "$APP/LICENSE-MIT"
check "LICENSE-MIT names the boundary tag" grep -q 'v0\.2\.0-mit' "$APP/LICENSE-MIT"

finish
