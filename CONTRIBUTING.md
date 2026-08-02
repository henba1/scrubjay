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

## Tests

```sh
tests/run.sh                 # everything
tests/run.sh adapters ship   # just tests/test_adapters.sh and tests/test_ship.sh
```

No framework — bash, `jq` and coreutils. Every test file runs in its own process with `$HOME`
moved into a temp dir (`tests/lib.sh`), so a run on your laptop does what a run on a fresh CI
runner does and cannot touch your `~/.claude` or your NAS. CI runs the suite on every PR.

Coverage is measured with [`kcov`](https://github.com/SimonKagstrom/kcov) and reported to
[Codecov](https://codecov.io/gh/henba1/scrubjay). It is **informational** — the number is there
to show which scripts nothing exercises, not to block a PR on a threshold. To reproduce what CI
computes:

```sh
kcov --include-path=bin,hooks coverage tests/run.sh
$BROWSER coverage/index.html
```

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
