---
description: Explain the current git diff in plain language (intent + risk)
argument-hint: "[optional path to scope the diff]"
allowed-tools: Bash(git diff:*), Bash(git status:*), Read
---
Summarize what the current uncommitted changes do and *why*, in plain language —
focus on intent and risk, not a line-by-line readout.

Current changes:

!`git status --short && echo '---' && git diff --stat $ARGUMENTS && echo '---' && git diff $ARGUMENTS`
