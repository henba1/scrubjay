# Licensing

scrubjay is **source-available**, not open source. The whole repository is public and readable; what changed is what you are permitted to *do* with it.

**Current licence: [FSL-1.1-ALv2](https://github.com/henba1/scrubjay/blob/main/LICENSE)** — the [Functional Source License](https://fsl.software/) 1.1, with an Apache-2.0 future licence.

## What you may do

The licence grants everything except one thing, so it is shorter to state the permission than the restriction. A **Permitted Purpose** is any purpose other than a Competing Use, and the licence calls out these explicitly:

- **Internal use and access.** Run scrubjay on your machines and on your company's machines, commercially, for as many people as you like. This is the normal case and it is unambiguously allowed.
- **Non-commercial education and research.**
- **Professional services you provide to someone who is themselves a licensee** using scrubjay under these terms.

You may also read, modify, fork, and redistribute it — the terms travel with the copy.

## The one restriction

You may not make scrubjay available to others **as a commercial product or service that competes with it**: something that substitutes for scrubjay, substitutes for a product or service we already offer using it, or offers substantially the same functionality.

Plainly: use it to run your own work, yes. Rebrand it and sell it as your own sync-and-recall product, no.

## It becomes Apache-2.0 on a timer

Every released version converts to the **Apache License 2.0 two years after its release**, automatically and irrevocably. The restriction above is a moving two-year window, not a permanent enclosure — today's code is Apache-2.0 in 2028 whatever happens to this project or its maintainer.

The repository therefore ships a [`NOTICE`](https://github.com/henba1/scrubjay/blob/main/NOTICE) file: Apache-2.0 §4(d) binds redistributors to it, but only if one exists, and it cannot be added to a version that has already converted. It carries attribution only — `LICENSE` governs.

## The MIT period

scrubjay was MIT-licensed from its first commit (2026-06-23) through the commit tagged [`v0.2.0-mit`](https://github.com/henba1/scrubjay/releases/tag/v0.2.0-mit).

**That grant is irrevocable.** Every copy, clone and fork taken at or before that tag remains available under MIT, permanently, and the current licence does not and cannot claw it back:

```
git checkout v0.2.0-mit   # the last MIT state, still MIT
```

The full MIT text and this explanation are kept in [`LICENSE-MIT`](https://github.com/henba1/scrubjay/blob/main/LICENSE-MIT) rather than deleted, because a project that quietly erases its own licensing history is harder to trust than one that writes it down. The relicence binds commits made *after* that tag.

## Per-file headers

Every shell, Python and JavaScript source file carries an [SPDX](https://spdx.dev/) header:

```
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.
```

`LICENSE` is the file a copied snippet leaves behind, so the terms are stamped on each file too — that way they survive vendoring, a fork, or an automated licence scan. `tests/test_license_headers.sh` fails the build if a source file is missing one.

Markdown, JSON and `skeleton/` are deliberately excluded: JSON cannot carry a comment, prose is covered by the repository licence, and `skeleton/` is seed content that becomes *your* private data repo — stamping a licence on your own config would be wrong.

## Contributing

Contributions are welcome and are accepted under the same terms — see [CONTRIBUTING.md](https://github.com/henba1/scrubjay/blob/main/CONTRIBUTING.md) for what you are granting when you open a pull request.

## Other terms

If the FSL doesn't fit what you need — including a licence to build something the Competing Use clause would otherwise prohibit — [open an issue](https://github.com/henba1/scrubjay/issues) and ask. Separate terms are available.
