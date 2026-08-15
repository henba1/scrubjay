# Test coverage

[![codecov](https://codecov.io/gh/henba1/scrubjay/branch/main/graph/badge.svg)](https://codecov.io/gh/henba1/scrubjay)

The suite is bash, `jq` and coreutils — no framework. Every test file runs in its own process with
`$HOME` moved into a temp dir, so a run on your laptop does what a run on a fresh CI runner does.
[CONTRIBUTING.md][contributing] has the commands, including how to reproduce the coverage number
locally.

Coverage is measured with [kcov][kcov] and reported to [Codecov][codecov]. It is **informational**:
it shows which scripts nothing exercises, and never blocks a PR. A threshold on a shell codebase
mostly buys tests that execute lines without asserting anything.

## Reading the graph

The [coverage grid][grid] gives one cell per file under `bin/` and `hooks/` — area is the file's
line count, colour is its coverage, red to green. It always renders the default branch; there is no
per-branch or per-PR view — `?branch=` on the SVG URL is accepted and ignored. For per-PR deltas,
line-level detail and click-through, use the [Codecov dashboard][codecov]; PRs get a comment only
when coverage actually moves.

[Sunburst][sunburst] and [icicle][icicle] renderings of the same data exist. They encode directory
nesting, which is nearly flat here, so the grid is usually the one worth looking at.

[grid]: https://codecov.io/gh/henba1/scrubjay/graphs/tree.svg

[contributing]: https://github.com/henba1/scrubjay/blob/main/CONTRIBUTING.md
[kcov]: https://github.com/SimonKagstrom/kcov
[codecov]: https://app.codecov.io/github/henba1/scrubjay
[sunburst]: https://codecov.io/gh/henba1/scrubjay/graphs/sunburst.svg
[icicle]: https://codecov.io/gh/henba1/scrubjay/graphs/icicle.svg
