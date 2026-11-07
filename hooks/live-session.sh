#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# A turn began, or the agent is asking for a permission: note it on the session's lease
# (bin/sj-live.sh). On UserPromptSubmit stdout is context, so nothing here may print.
[ "${SCRUBJAY_NO_HOOKS:-0}" = "1" ] && exit 0
APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
bash "$APP/bin/sj-live.sh" hook >/dev/null 2>&1
exit 0
