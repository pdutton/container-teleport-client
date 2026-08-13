# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Build and test

Requires Podman and GNU Make.

```bash
make help    # lists every user-facing target and the pinned version
make build   # builds localhost/teleport-client and applies the full tag set
make test    # builds, then runs test/smoke.sh inside the built image
make clean   # removes this repo's four tags
make push    # builds, tests, then publishes every tag (needs registry credentials)
```

(`make help` doesn't enumerate `tag` — it's a real target and directly
invocable (`make tag`), not just an internal step `build` calls; the wording
above says "every user-facing target" rather than "every target" for that
reason.)

`make test` is the entire test story. There is no lint step and no unit test
suite. It runs three checks outside the image before the smoke test runs
inside it: `README.md` mentions the pinned version (grep), the
`org.opencontainers.image.licenses` label is exactly
`LicenseRef-Teleport-Community-Edition`, and the
`org.opencontainers.image.description` label contains the pinned version (i.e.
actually interpolates it rather than being hand-typed) — all via `podman image
inspect`. The smoke test itself runs entirely offline inside the built image —
it asserts `tsh`'s path, version, and absence of
`teleport`/`tctl`/`tbot`/`curl`/`wget`, that the CA store exists, that the
licence file is present and contains text unique to the Teleport Community
Edition License (not just that it's non-empty — `tsh` itself or this repo's own
AGPL `LICENSE` would also pass a size-only check), and that `$HOME/.tsh` can be
created and written. It cannot verify an actual login: that needs a real
cluster, a password and a second factor, so end-to-end verification of `tsh
login` and the port-forward tunnel is a manual step after any version bump.

## Publishing

Images go to `docker.io/pdutton/teleport-client`. `REGISTRY` overrides the
destination (`make push REGISTRY=ghcr.io/pdutton`). Every local image reference
goes through `LOCAL_IMAGE` (`localhost/$(IMAGE)`) — no bare `$(IMAGE)` may be
reintroduced as an image reference, because a bare short name can resolve to a
non-localhost repo and the push source must not depend on that tie-break.

The four-tag scheme — `latest`, `18`, `18.10`, `18.10.4` — lives in `TAG_SET_SH`
in the Makefile and is expanded by both `tag` and `push`, so it is defined once.
Tags are derived by reading `tsh version` back out of the freshly built image,
not typed by hand, so they cannot drift from what is actually installed.

There is no `ubuntu` tag. With a single image (one `Containerfile`, one base OS)
it would be a permanent alias of `latest` — a second name meaning exactly the
same thing, kept in sync for no benefit. `container-ansible` publishes an
`ubuntu` tag because it also publishes `alpine`; that contrast is what gives the
name meaning there, and it doesn't exist here (D9).

## How the version is pinned

Teleport `18.10.4` is pinned in three places, and `make test` now cross-checks
all three:

| Where | Purpose | Cross-checked? |
|---|---|---|
| `ARG TELEPORT_VERSION` in `Containerfile` | what actually gets downloaded | yes |
| `TELEPORT_VERSION` in `Makefile` | passed to the smoke test as `EXPECT_VERSION` | yes |
| the version in `README.md` | documentation | yes — `make test` greps for it |

The Makefile's copy is deliberately never passed as a `--build-arg`. That does
*not* mean the smoke test's version assertion would be vacuous if it were:
`EXPECT_VERSION` is checked against what `tsh version` itself reports, so even
a single shared source of truth would still verify that the tarball at that URL
really contains a `tsh` reporting that version and that extraction pulled the
right archive member — a real upstream-correspondence check either way. What
the split actually buys is narrower: it catches a human editing one file and
not the other. Because they're independent, editing one alone does not break
`podman build` — the image builds fine — it breaks `make test`. That's the
safety net working as designed, not a bug. The README copy no longer goes stale
silently either: `make test` greps `README.md` for `$(TELEPORT_VERSION)` and
fails loudly if it's missing. Still update it by hand in the same commit as any
bump — the grep only checks the number appears, not that the prose around it is
accurate.

Bumping the pinned version means editing **four** things, not one:
`TELEPORT_VERSION` in the Makefile, `ARG TELEPORT_VERSION` in the Containerfile,
**both** `ARG TELEPORT_SHA256_AMD64` / `ARG TELEPORT_SHA256_ARM64` digests in
the Containerfile (see "Digest pin" below), and the version named in
`README.md`.

This isn't a stylistic choice diverging from the sibling repos' resolve-at-build
pattern — it's forced. There is no usable release index for Teleport (M2 in the
design spec): the only `updates.releases.teleport.dev` channel that answers is
`cloud`, which has nothing to do with the self-hosted Community line, and the
GitHub releases API omits published versions outright (18.10.4 is served by the
CDN but never appears in that API's list). A resolver built on either source
would silently pin the wrong thing while believing itself current.

## Digest pin

Pinning the version number alone only protects against podman's layer cache
serving something stale — it does nothing on a cache miss (any CI run on a
fresh runner, `--pull`), which re-fetches from `cdn.teleport.dev` and trusts
whatever is served under that version's name at that moment. A tarball silently
republished under the same version would pass the same-host `.sha256` check
unnoticed.

The Containerfile therefore also pins an expected SHA-256 digest per
architecture — `ARG TELEPORT_SHA256_AMD64` and `ARG TELEPORT_SHA256_ARM64`,
selected by the same `case "$(uname -m)"` that picks the download URL — and
fails the build loudly, naming both the expected and actual digest, if the
downloaded tarball doesn't match. The current values were verified against
`cdn.teleport.dev` on 2026-08-12 for v18.10.4. This is still **integrity, not
authenticity** — it binds the build to bytes a human looked at on that date, not
proof Teleport authored them, since the pin itself came from the same unsigned
CDN download it now protects against future substitution. See D6 in the design
spec.

## Licensing

This repo's own code — `Containerfile`, `Makefile`, `test/smoke.sh`, docs — is
**AGPL-3.0-only** (see `LICENSE`), deliberately diverging from the
GPL-3.0-or-later `container-ansible`/`container-terraform` siblings, to align
with the licence on Teleport's own source repository.

The `tsh` binary the image *ships* is under the **Teleport Community Edition
License**, which is neither AGPL nor stock Apache-2.0 — do not conflate the two.
SPDX has no identifier for it, so the image label reads:

```
org.opencontainers.image.licenses="LicenseRef-Teleport-Community-Edition"
```

`LicenseRef-` is SPDX's escape hatch for licences without an identifier. See M5
in the design spec for the quoted licence text and the eligibility condition
(individuals, and organizations under 100 employees and $10M annual revenue).

`/usr/share/doc/teleport/LICENSE-community` must keep travelling inside the
image: §4(a) of that licence requires giving recipients a copy when
redistributing, and publishing this image is such a redistribution. `test/smoke.sh`
guards this file's presence and, specifically, that it contains text unique to
the Teleport Community Edition License — not just that it's non-empty, since
`tsh` itself or this repo's own AGPL `LICENSE` would also pass a size-only
check. It's the one assertion in the smoke test that protects a licence
obligation rather than a feature, since a refactor of the `COPY --from` lines
could silently drop it or point it at the wrong file.

## Design docs

- `docs/superpowers/specs/2026-08-12-teleport-client-image-design.md` — the
  authority for the image's shape, version pinning, tags and licensing. Read
  this before changing any of them.
- `docs/superpowers/plans/2026-08-12-teleport-client-image.md` — how it was
  built, task by task.

## Sibling repos

`~/projects/container-ansible/primary/` and `~/projects/container-terraform/primary/`
share the build conventions this repo follows (Makefile shape, tagging by
reading the version back out of the built image, offline smoke tests). Read
either before changing build machinery here.

`~/projects/teleport/primary/` holds the cluster this client talks to.
`SETUP-CLIENT.md` there is the authority for cluster-side steps this repo does
not touch — creating a user, the invite URL, MFA enrollment.
