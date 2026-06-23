---
name: feedback-no-coauthored-by
description: Never add Co-Authored-By Claude trailer to git commits or PRs
metadata:
  node_type: memory
  type: feedback
---

Never add "Co-Authored-By: Claude ..." to git commit messages or PR descriptions.

**Why:** User wants only their own name in git history.

**How to apply:** Omit the Co-Authored-By trailer entirely from all commit messages.
This is also enforced via `attribution.commit: ""` and `attribution.pr: ""` in
`~/.claude/settings.json`.
