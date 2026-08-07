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
- **Every new `.sh`, `.py` or `.js` file starts with the SPDX licence header**, directly under the
  shebang (`//` instead of `#` for JavaScript):

  ```sh
  # SPDX-License-Identifier: FSL-1.1-ALv2
  # Copyright (c) 2026 Hendrik Baacke. See LICENSE.
  ```

  Not in Markdown, JSON, or `skeleton/`. `bash tests/run.sh license_headers` checks this — including
  files you haven't staged yet — so you'll catch a miss before CI does.

## Licensing

scrubjay is **source-available** under [FSL-1.1-ALv2](LICENSE), not open source: use it for
anything including inside your company, but don't resell it as a competing product. Each release
becomes Apache-2.0 two years on. Everything up to the tag `v0.2.0-mit` was MIT and stays MIT — see
[`LICENSE-MIT`](LICENSE-MIT) and the [Licensing](docs/licensing.md) page.

By opening a pull request you agree that your contribution is licensed under the same terms, and
you grant the maintainer the right to release it under the project's future licence terms — the
Apache-2.0 conversion, and any other terms the project is offered under. Without that, the two-year
conversion the licence promises could not be honoured for contributed code. If your employer owns
your work, please make sure you have their sign-off before contributing.

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
