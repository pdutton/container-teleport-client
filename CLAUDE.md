# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Build and test

Requires Podman and GNU Make.

```bash
make help    # lists every user-facing target and the pinned version
make build   # builds both variants of localhost/teleport-client, applies the full tag set
make test    # builds, then runs test/smoke.sh inside each built image
make clean   # removes this repo's ten tags
make push    # builds, tests, then publishes every tag (needs registry credentials)
```

(`make help` doesn't enumerate `tag` — it's a real target and directly
invocable (`make tag`), not just an internal step `build` calls; the wording
above says "every user-facing target" rather than "every target" for that
reason.)

## Variants

Two images come off one `Containerfile`, separated by a single build arg,
`INCLUDE_TCTL` (D12):

| Variant | Contents | Base tag | Full tag set |
|---|---|---|---|
| `tsh` | `tsh` | `latest` | `latest` `tsh` `18` `18.10` `18.10.4` |
| `admin` | `tsh` + `tctl` | `admin` | `admin` `tctl` `18-admin` `18.10-admin` `18.10.4-admin` |

The arg is read only in the downloader stage, where it decides which members
`tar` extracts. The final stage does a directory copy (`COPY /out/bin/`) so it
stays ignorant of the variant — `LABEL` and `COPY` cannot branch on a build
arg, and this is what avoids needing them to.

Every per-variant value is a row in the variant block near the top of the
Makefile, read from the recipes as `$(<SETTING>_$(VARIANT))`. Each plain target
(`build`, `tag`, `test`, `push`) re-invokes make once per variant against the
matching `-variant` target; those require `VARIANT` and refuse to run without
it, since make would otherwise expand `$(BASE_TAG_)` to nothing and fail
somewhere much less obvious.

A third variant would need a row in each table, a branch in `TAG_SET_SH`, a
name in `REQUIRE_VARIANT_SH`, and a line in each plain target — but no new
recipe. The per-variant fan-out is written out literally rather than looped over
a `VARIANTS` list so that `make -n` stays readable and a non-zero exit cannot be
swallowed by a `for` loop in a recipe.

The description label is the one thing the Containerfile cannot supply for both
variants, because `LABEL` has no conditionals. The admin build overrides
`org.opencontainers.image.description` from the command line, alongside the
`created` and `revision` labels the Makefile already sets there. The tsh build
deliberately does *not* override it: leaving it to the Containerfile's own
`LABEL` is what keeps the D3 check comparing two independently written copies.

## Testing

`make test` is the entire test story. There is no lint step and no unit test
suite. It greps `README.md` for the pinned version once, then runs per variant:
the `org.opencontainers.image.licenses` label is exactly
`LicenseRef-Teleport-Community-Edition`, the
`org.opencontainers.image.description` label matches that variant's expected
string with the pinned version interpolated (i.e. not hand-typed) — both via
`podman image inspect` — and then the smoke test inside the image.

The smoke test runs entirely offline inside the built image. It asserts `tsh`'s
path and version, the absence of `teleport`/`tbot`/`curl`/`wget`, that the CA
store exists, that the licence file is present and contains text unique to the
Teleport Community Edition License (not just that it's non-empty — `tsh` itself
or this repo's own AGPL `LICENSE` would also pass a size-only check), and that
`$HOME/.tsh` can be created and written.

`tctl` is asserted in **both** directions, driven by `EXPECT_TCTL`: present and
reporting the pinned version in the admin variant, absent in the default one.
Both halves matter. An accidental inclusion is 111 MB and an admin tool in the
image people get without asking; an accidental omission leaves the `admin` tag
published and useless, which nothing else would catch — every other assertion
still passes on a tsh-only image. `EXPECT_TCTL` is validated against exactly
`yes`/`no` for the same reason `INCLUDE_TCTL` is validated against exactly
`true`/`false`: a typo that fell through to the negative branch would turn the
admin variant's reason for existing into an assertion that passes.

It cannot verify an actual login, or that `tctl` administers anything: those
need a real cluster, a password, a second factor, and a privileged role. So
end-to-end verification of `tsh login`, the port-forward tunnel, and any real
`tctl` command is a manual step after any version bump.

## Publishing

Images go to `docker.io/pdutton/teleport-client`. `REGISTRY` overrides the
destination (`make push REGISTRY=ghcr.io/pdutton`). Every local image reference
goes through `LOCAL_IMAGE` (`localhost/$(IMAGE)`) — no bare `$(IMAGE)` may be
reintroduced as an image reference, because a bare short name can resolve to a
non-localhost repo and the push source must not depend on that tie-break.

The ten-tag scheme lives in `TAG_SET_SH` in the Makefile, which switches on
`$(VARIANT)` and is expanded by both `tag-variant` and `push-variant`, so it is
defined once. Tags are derived by reading `tsh version` back out of the freshly
built image, not typed by hand, so they cannot drift from what is actually
installed. `tsh` is what gets read, not `tctl`, because it is the one binary
both variants carry.

`tsh` and `tctl` are aliases of `latest` and `admin`. That is not the same
mistake as an `ubuntu` tag would be: a tag earns its keep when a sibling name
gives it contrast, and `tsh` reads as a choice only because `tctl` sits beside
it. `container-ansible`'s `ubuntu` tag works for exactly that reason — it also
publishes `alpine`. There is still no `ubuntu` tag *here*, because this repo
still has one base OS and nothing to contrast it with (D9, D12).

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

The Teleport binaries the images *ship* — `tsh`, plus `tctl` in the admin
variant — are under the **Teleport Community Edition License**, which is neither
AGPL nor stock Apache-2.0 — do not conflate the two. Both come out of the same
tarball under the same licence, so the admin variant raises no licensing
question the default does not.
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
