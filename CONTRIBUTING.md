# Contributing

Thanks for your interest in scrubjay!

## Scope

This repo is the **app/logic only** — shell scripts, hooks, the MCP server, and docs. The
maintainer's personal configuration and chat transcripts live in *separate private* repos
(`scrubjay-data`, `scrubjay-chats`) that are intentionally not here. Please keep this repo
public-safe: no real hostnames, personal paths, IPs, or emails — use RFC-safe placeholders
(`192.168.x`, `home.ddns.example`, `scrubjay-rx`, `laptop`).

## Development

- Scripts are `bash` with `set -uo pipefail`. Match the surrounding style; prefer reusing
  helpers in `bin/lib.sh` over new code.
- Run [`shellcheck`](https://www.shellcheck.net/) on scripts you touch.
- Never commit credentials, `.env`, or `*.key`. The `.gitignore` blocks `*.jsonl`,
  `*.credentials*`, and `.claude.json`.

## Docs

The documentation site is MkDocs Material under `docs/` (config in `mkdocs.yml`). Build and
preview locally:

```sh
pip install -r requirements-docs.txt
mkdocs serve            # http://127.0.0.1:8000
mkdocs build --strict   # fails on broken internal links — run before opening a PR
```

Pushing doc changes to `main` publishes the site via the `docs` GitHub Actions workflow.

## Pull requests

- Keep PRs focused; describe the change and how you verified it.
- The maintainer works solo and deploys from `main`; small, reviewable commits are preferred.
