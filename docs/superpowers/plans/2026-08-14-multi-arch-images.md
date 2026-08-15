# Multi-Arch Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `linux/amd64` and `linux/arm64` images under the existing ten
tags, as manifest lists, so `podman pull …:latest` resolves to the puller's
architecture.

**Architecture:** The `Containerfile` does not change — its `case "$(uname -m)"`
already selects the right tarball and digest pin, and reports `aarch64` both
under QEMU and on a native `arm64` runner. All the work is in the Makefile,
which gains `ARCH` as a second fan-out dimension beside `VARIANT`, and in CI,
which builds each architecture on a runner of that architecture and assembles
the lists in a third job.

**Tech Stack:** GNU Make, podman 5.8.1 (`podman manifest`), POSIX `sh`, GitHub
Actions.

**Spec:** `docs/superpowers/specs/2026-08-12-teleport-client-image-design.md` —
D13, D14, D15 and M6 are the records this plan implements. D9 and D11 carry
annotations pointing at them. Read those five before starting.

**Worktree:** `/home/pdutton/projects/container-teleport/feature/multi-arch`,
branch `feature/multi-arch`. Every `git` and `make` command below runs there.
Never commit in `primary/`.

## Global Constraints

- **Architectures are exactly `amd64` and `arm64`.** Teleport also publishes
  `linux-arm` and `linux-386` tarballs; both are deliberately out of scope (see
  Out of scope in the spec). No third architecture in this work.
- **The `Containerfile` is not modified by this plan.** If a task seems to need
  a change there, stop — that contradicts D13 and needs a spec amendment first.
- **Pinned Teleport version: `18.10.4`.** Do not bump it here.
- **Published tag surface after this work:** ten manifest lists —
  `latest` `tsh` `18` `18.10` `18.10.4` `admin` `tctl` `18-admin` `18.10-admin`
  `18.10.4-admin` — plus exactly four plain images: `latest-amd64`,
  `latest-arm64`, `admin-amd64`, `admin-arm64`. Arch suffixes go on the *base
  tag only*, never on all five names of a variant.
- **Local per-arch tag format:** `$(BASE_TAG_$(VARIANT))-$(ARCH)`, e.g.
  `localhost/teleport-client:admin-arm64`.
- **Registry:** `docker.io/pdutton/teleport-client`, via `$(REGISTRY)/$(IMAGE)`.
  Every local reference goes through `$(LOCAL_IMAGE)`; a bare `$(IMAGE)` must
  never be reintroduced as an image reference.
- **Fan-out is written out literally, never looped over a list variable.** Two
  literal `$(MAKE)` lines survive `make -n` legibly and cannot swallow a
  non-zero exit the way a `for` loop in a recipe can. This is the rule the
  variant block already states; the arch block follows it.
- **Guards are exact-match `case` statements.** `REQUIRE_ARCH_SH` matches
  exactly `amd64|arm64`, `EXPECT_ARCH` exactly `amd64|arm64` — same reasoning as
  `EXPECT_TCTL`'s `yes|no`: a value falling through to the wrong branch turns an
  assertion into a pass.
- **Commit style:** `feat:` / `test:` / `ci:` / `docs:` prefixes, imperative
  subject, body explaining *why*. Match the existing log.

### Target hierarchy this plan builds

Three levels, each named for what it does. Read this before Task 2.

| Target | Inputs required | Scope |
|---|---|---|
| `build` / `test` / `push` | none | everything: 2 variants × 2 arches, then manifests |
| `build-arch` / `test-arch` / `push-arch` | `ARCH` | both variants, one architecture — **the unit of work one CI runner does** |
| `build-image` / `test-image` / `push-image` / `stamp-image` | `VARIANT`, `ARCH` | exactly one image |
| `manifests` / `push-manifests` | none (`VERSION`, `MANIFEST_SRC` optional) | both variants' lists |
| `manifest-variant` / `push-manifest-variant` | `VARIANT` (+ `VERSION`) | one variant's five lists |

### Timing

A full local `make test` builds four images, two of them emulated, and the
`arm64` half downloads and extracts a 217 MB tarball under QEMU.

**Measured, from a completely cleared podman cache: about 3 minutes.** CI is
faster still, since both architectures build natively and in parallel — around
50-60 seconds per architecture.

An earlier draft of this plan warned of 20-45 minutes. That was wrong, and
wrong in an instructive way: it generalised from watching one `arm64` build sit
in `update-ca-certificates`, where each certificate check is a separate emulated
process spawn. That phase is genuinely the slowest part of the emulated build,
but it is seconds, not tens of minutes, and the rest of the build is fast enough
that the whole thing finishes in about the time a single native build takes.
Emulation is a real cost here; it is not the order-of-magnitude cost the earlier
number implied.

Narrowing to one architecture (`make build-arch ARCH=amd64`) is still the
quicker inner loop, but the full sweep is cheap enough to run whenever you want
reassurance.

---

### Task 1: Assert the architecture inside the image

`test/smoke.sh` currently cannot tell an `amd64` image from an `arm64` one. Per
D13 this is the assertion that catches a `--platform` dropped from one of the
two `podman build` invocations — which would otherwise publish an `amd64` image
under an `arm64` name and satisfy every check that already exists.

This task changes the smoke test and the one Makefile line that invokes it,
together, because `EXPECT_ARCH` is mandatory: splitting them would leave
`make test` broken at a commit boundary.

**Files:**
- Modify: `test/smoke.sh` (add required env at `:4-5`, validation after `:16`, new assertion block after `:32`)
- Modify: `Makefile:239-242` (the `podman run` in `test-variant`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `test/smoke.sh` requires env `EXPECT_ARCH`, exactly `amd64` or
  `arm64`. Every later task that runs the smoke test must pass it.

- [ ] **Step 1: Watch the assertion fail before writing it**

There is no unit-test harness here — `make test` is the entire test story — so
the "failing test" is the smoke test run against an image it should reject.
Build one image to work with:

```bash
make build-variant VARIANT=tsh
```

Now run the smoke test by hand, claiming the wrong architecture:

```bash
podman run --rm -v ./test:/apps:ro,z \
  -e EXPECT_VERSION=18.10.4 -e EXPECT_TCTL=no -e EXPECT_ARCH=arm64 \
  localhost/teleport-client:latest sh /apps/smoke.sh
```

Expected: **PASS** — and that is the bug. The script ignores `EXPECT_ARCH`
entirely, so it happily certifies an `amd64` image as `arm64`.

- [ ] **Step 2: Require and validate `EXPECT_ARCH`**

In `test/smoke.sh`, add the third required variable beside the existing two:

```sh
: "${EXPECT_VERSION:?EXPECT_VERSION must be set}"
: "${EXPECT_TCTL:?EXPECT_TCTL must be set to yes or no}"
: "${EXPECT_ARCH:?EXPECT_ARCH must be set to amd64 or arm64}"
```

Then, immediately after the existing `EXPECT_TCTL` `case` block (which ends at
line 16 with `esac`), add its counterpart:

```sh
# Same exact-match rule as EXPECT_TCTL above, for the same reason (D13): a value
# that fell through to a wrong branch would turn this assertion into a pass, and
# the whole point of it is to catch a --platform that went missing.
case "$EXPECT_ARCH" in
  amd64|arm64) ;;
  *) fail "EXPECT_ARCH is '$EXPECT_ARCH', expected exactly 'amd64' or 'arm64'" ;;
esac
```

- [ ] **Step 3: Add the assertion itself**

Insert after the version check (after line 32, `|| fail "tsh is $version, expected $EXPECT_VERSION"`), before the `(c)` exclusions block:

```sh
# (b2) The image must actually be the architecture it is named for (D13). The
# Containerfile picks the tarball from `uname -m`, so this is also a check that
# the extraction pulled the arch-matching member -- but its real job is catching
# a `--platform` dropped from one of the two builds in the Makefile, which would
# publish an amd64 image under an arm64 tag with every other assertion here
# still passing. Under qemu-user the emulated `uname` reports the target
# machine, so this reads the same way emulated and native.
machine="$(uname -m)"
case "$machine" in
  x86_64)  arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) fail "uname -m is '$machine', which is neither architecture this image is built for" ;;
esac
echo "architecture: $arch"
[ "$arch" = "$EXPECT_ARCH" ] \
  || fail "image is $arch, expected $EXPECT_ARCH"
```

- [ ] **Step 4: Run it to verify it now fails**

```bash
podman run --rm -v ./test:/apps:ro,z \
  -e EXPECT_VERSION=18.10.4 -e EXPECT_TCTL=no -e EXPECT_ARCH=arm64 \
  localhost/teleport-client:latest sh /apps/smoke.sh
```

Expected: exit 1, with `FAIL: image is amd64, expected arm64`.

Then check the omission case — the script must refuse to run at all rather than
default to something:

```bash
podman run --rm -v ./test:/apps:ro,z \
  -e EXPECT_VERSION=18.10.4 -e EXPECT_TCTL=no \
  localhost/teleport-client:latest sh /apps/smoke.sh
```

Expected: exit 1, `EXPECT_ARCH must be set to amd64 or arm64`.

And the invalid-value case:

```bash
podman run --rm -v ./test:/apps:ro,z \
  -e EXPECT_VERSION=18.10.4 -e EXPECT_TCTL=no -e EXPECT_ARCH=x86_64 \
  localhost/teleport-client:latest sh /apps/smoke.sh
```

Expected: exit 1, `FAIL: EXPECT_ARCH is 'x86_64', expected exactly 'amd64' or 'arm64'`.
(`x86_64` is the deliberate trap: it is what `uname -m` says, and it is *not* a
valid `EXPECT_ARCH`.)

- [ ] **Step 5: Pass the variable from the Makefile**

`Makefile:239-242` — add the one line so `make test` keeps working. `ARCH` does
not exist as a Makefile variable yet; that is Task 2, so hardcode the host
architecture here and let Task 2 replace it. Change:

```make
	$(PODMAN) run --rm -v ./test:/apps:ro,z \
	  -e EXPECT_VERSION=$(TELEPORT_VERSION) \
	  -e EXPECT_TCTL=$(EXPECT_TCTL_$(VARIANT)) \
	  $(LOCAL_IMAGE):$(BASE_TAG_$(VARIANT)) sh /apps/smoke.sh
```

to:

```make
	$(PODMAN) run --rm -v ./test:/apps:ro,z \
	  -e EXPECT_VERSION=$(TELEPORT_VERSION) \
	  -e EXPECT_TCTL=$(EXPECT_TCTL_$(VARIANT)) \
	  -e EXPECT_ARCH=$(HOST_ARCH) \
	  $(LOCAL_IMAGE):$(BASE_TAG_$(VARIANT)) sh /apps/smoke.sh
```

and add `HOST_ARCH` next to the other tool/host variables, after
`Makefile:22` (`PODMAN   ?= /usr/bin/podman`):

```make
# The architecture of the machine running make, in podman's naming rather than
# uname's. Task 2 makes this the default for ARCH; until then it is what the
# smoke test is told to expect.
HOST_ARCH := $(patsubst aarch64,arm64,$(patsubst x86_64,amd64,$(shell uname -m)))
```

- [ ] **Step 6: Verify the real path passes**

```bash
make test
```

Expected: both variants PASS, and each smoke run now prints an
`architecture: amd64` line (on an `x86_64` host) alongside `tsh version:`.

- [ ] **Step 7: Commit**

```bash
git add test/smoke.sh Makefile
git commit -m "test: assert the image's architecture in the smoke test

EXPECT_ARCH, validated against exactly amd64|arm64 for the same reason
EXPECT_TCTL is validated against exactly yes|no -- a value falling through to
the wrong branch turns the assertion into a pass.

This is the check that catches a --platform dropped from one of the builds
multi-arch is about to add. Without it an amd64 image published under an arm64
name satisfies every other assertion in the file.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `ARCH` as a second fan-out dimension to the build

Restructures the build half of the Makefile: `build-variant` and the stamping
half of `tag-variant` become `build-image` and `stamp-image`, keyed on both
`VARIANT` and `ARCH`, writing to `<base>-<arch>` tags. The canonical tag set is
*not* applied here any more — from Task 4 onward those ten names are manifest
lists, so nothing between now and Task 4 creates them. That is expected.

**Files:**
- Modify: `Makefile` — new arch block after the variant block (after `:85`), replace `build`/`build-variant` (`:161-174`), replace `tag`/`tag-variant` (`:176-196`), update `.PHONY` (`:141`)

**Interfaces:**
- Consumes: `HOST_ARCH` from Task 1.
- Produces:
  - `PLATFORM_amd64` = `linux/amd64`, `PLATFORM_arm64` = `linux/arm64`
  - `ARCH_TAG` = `$(BASE_TAG_$(VARIANT))-$(ARCH)` (recursive `=`, tracks
    command-line `VARIANT`/`ARCH`)
  - `REQUIRE_ARCH_SH` — guard shell snippet, same shape as `REQUIRE_VARIANT_SH`
  - `READ_VERSION` — `$(call READ_VERSION,<variant>)`, expands to a shell
    command substitution yielding that variant's stamped version string
  - targets `build`, `build-arch` (needs `ARCH`), `build-image` and
    `stamp-image` (need `VARIANT` and `ARCH`)

- [ ] **Step 1: Add the architecture block**

Insert after the variant block's last line (`Makefile:85`, the
`DESC_LABEL_admin :=` line) and before the `REQUIRE_VARIANT_SH` comment:

```make
# ---- architectures ----------------------------------------------------------
# Two architectures, one Containerfile, one --platform flag between them (D13).
#
# The Containerfile needs no architecture knowledge from here and is not
# modified by any of this: its `case "$(uname -m)"` reports aarch64 both under
# the qemu-user registration this machine already has (M6) and on a native
# arm64 runner, so the same file is correct in both halves of D15.
#
# Same written-out fan-out rule as the variant block: two literal lines, no
# ARCHES list looped over in a recipe. Adding a third architecture means a row
# here, a name in REQUIRE_ARCH_SH, a `podman manifest add` line in
# manifest-variant, one line in each plain target, and a `case` arm plus a
# digest ARG in the Containerfile.
PLATFORM_amd64 := linux/amd64
PLATFORM_arm64 := linux/arm64

# Where each architecture's image lands locally: the variant's base tag with the
# architecture appended, e.g. localhost/teleport-client:admin-arm64. Only the
# base tag is suffixed -- the other four names of a variant become manifest
# lists (D14) and never carry an architecture. `=` (recursive), not `:=`, so
# this tracks VARIANT and ARCH set on a sub-make command line.
ARCH_TAG = $(BASE_TAG_$(VARIANT))-$(ARCH)

# Guard for the `-image` and `-arch` targets, exactly parallel to
# REQUIRE_VARIANT_SH below and needed for the same reason: make expands an unset
# $(PLATFORM_) to nothing rather than complaining, so without this a bare
# `make build-image` would hand podman an empty --platform and fail somewhere
# much less obvious.
REQUIRE_ARCH_SH = case "$(ARCH)" in \
                    amd64|arm64) ;; \
                    *) echo "ERROR: this target needs ARCH=amd64 or ARCH=arm64 (got '$(ARCH)'). Run the plain target -- build, test, push -- which does both." >&2; exit 1 ;; \
                  esac

# $(call READ_VERSION,<variant>) -- the version stamp-image wrote onto that
# variant's image, read back with an inspect rather than a container start.
# Reads the host-architecture member specifically: any member would do (the
# smoke test pins every one of them to TELEPORT_VERSION), and the host's is the
# one that needs no emulation just to read a label.
READ_VERSION = $$($(PODMAN) image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' $(LOCAL_IMAGE):$(BASE_TAG_$(1))-$(HOST_ARCH))
```

Move the `HOST_ARCH` definition Task 1 put near `PODMAN` down into this block,
above `PLATFORM_amd64` — it belongs with the other architecture settings now.

- [ ] **Step 2: Replace `build` and `build-variant`**

Replace `Makefile:161-174` entirely with:

```make
build:
	@$(MAKE) --no-print-directory build-arch ARCH=amd64
	@$(MAKE) --no-print-directory build-arch ARCH=arm64
	@$(MAKE) --no-print-directory manifests

# One architecture, both variants -- the unit of work a single CI runner does.
build-arch:
	@set -eu; $(REQUIRE_ARCH_SH)
	@$(MAKE) --no-print-directory build-image VARIANT=tsh   ARCH=$(ARCH)
	@$(MAKE) --no-print-directory build-image VARIANT=admin ARCH=$(ARCH)

build-image:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; $(REQUIRE_ARCH_SH)
	$(PODMAN) build --platform $(PLATFORM_$(ARCH)) -t $(LOCAL_IMAGE):$(ARCH_TAG) \
	  --build-arg INCLUDE_TCTL=$(INCLUDE_TCTL_$(VARIANT)) \
	  $(DESC_LABEL_$(VARIANT)) \
	  --label org.opencontainers.image.created=$(BUILD_DATE) \
	  --label org.opencontainers.image.revision=$(GIT_REV) \
	  $(PODMAN_BUILD_FLAGS) \
	  .
	@$(MAKE) --no-print-directory stamp-image VARIANT=$(VARIANT) ARCH=$(ARCH)
```

`manifests` does not exist until Task 4. Until then `make build` will fail on
its last line — that is expected and Step 5 works around it.

- [ ] **Step 3: Replace `tag`/`tag-variant` with `stamp-image`**

Replace `Makefile:176-196` (the `tag` target, its comment block, and
`tag-variant`) with:

```make
# Read the version out of the freshly built image and stamp it on as a label, so
# the tag set derived from it later cannot drift from what is actually
# installed. `tsh version` prints "Teleport v18.10.4 git:... go1.25.11" on its
# first line; field 2 is the version and the leading v is stripped. tsh is read
# rather than tctl because it is the one binary both variants have.
#
# Applying tags is no longer this target's job: from D14 the five names a
# variant carries are manifest lists, created by manifest-variant, and the only
# plain tag an image has is the arch-suffixed one it was built under.
#
# --platform is passed to the label build as well as the first one. It is not
# decoration: podman would otherwise re-resolve `FROM localhost/...:admin-arm64`
# to the host architecture and silently replace an arm64 image with an amd64 one
# under the arm64 tag. PODMAN_BUILD_FLAGS is deliberately still not threaded
# through here -- it exists for `--pull` against the base images, which this
# build does not fetch.
stamp-image:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; $(REQUIRE_ARCH_SH)
	@set -eu; \
	version=$$($(PODMAN) run --rm --platform $(PLATFORM_$(ARCH)) $(LOCAL_IMAGE):$(ARCH_TAG) tsh version | $(AWK) 'NR==1{print $$2}'); \
	version=$${version#v}; \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(LOCAL_IMAGE)" "$(ARCH_TAG)" "$$version" \
	  | $(PODMAN) build --platform $(PLATFORM_$(ARCH)) -f - -t "$(LOCAL_IMAGE):$(ARCH_TAG)" .; \
	echo "Stamped $(LOCAL_IMAGE):$(ARCH_TAG) with version $$version"
```

The `X.Y.Z` shape check is not duplicated here. It stays in `TAG_SET_SH`, which
still runs before any tag or list name is derived (Task 4) — one definition, as
the comment on `TAG_SET_SH` says.

- [ ] **Step 4: Update `.PHONY`**

`Makefile:141` becomes:

```make
.PHONY: help build build-arch build-image stamp-image test test-arch test-image \
        manifests manifest-variant push push-arch push-image push-manifests \
        push-manifest-variant clean
```

All of these are declared now even though Tasks 3–5 add the recipes; a `.PHONY`
name with no rule is harmless and keeps the list in one edit.

- [ ] **Step 5: Verify the guard, then build both architectures**

First the guard, which needs no build at all:

```bash
make build-image VARIANT=tsh
```

Expected: exit 1, `ERROR: this target needs ARCH=amd64 or ARCH=arm64 (got '')`.

```bash
make build-image ARCH=amd64
```

Expected: exit 1, the `VARIANT` error — the variant guard runs first.

Now build the native architecture:

```bash
make build-arch ARCH=amd64
podman images --format '{{.Repository}}:{{.Tag}}' | grep teleport-client
```

Expected: `localhost/teleport-client:latest-amd64` and
`localhost/teleport-client:admin-amd64`, and no bare `latest`/`admin`.

Then the emulated one (slower than the native build, but a matter of minutes,
not tens of them):

```bash
make build-arch ARCH=arm64
```

Expected: two more tags, `latest-arm64` and `admin-arm64`.

- [ ] **Step 6: Verify the architectures are real, not just named**

This is the check the whole task exists to make possible:

```bash
podman image inspect --format '{{.Architecture}}' localhost/teleport-client:latest-amd64
podman image inspect --format '{{.Architecture}}' localhost/teleport-client:latest-arm64
podman image inspect --format '{{.Architecture}}' localhost/teleport-client:admin-arm64
```

Expected: `amd64`, `arm64`, `arm64`. If the `arm64` ones report `amd64`, the
`--platform` on the `stamp-image` label build is missing or wrong — that is
precisely the failure D13 predicts.

Confirm the version label landed on an emulated image too:

```bash
podman image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  localhost/teleport-client:latest-arm64
```

Expected: `18.10.4`.

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "feat: build each variant for amd64 and arm64

Adds ARCH beside VARIANT as a second fan-out dimension, in the same written-out
style the variant block uses and for the same reasons: `make -n` stays readable
and a for loop in a recipe cannot swallow a non-zero exit.

build-image builds one (variant, arch) into <base>-<arch>; build-arch does both
variants for one architecture, which is the unit of work one CI runner will do.
tag-variant splits: the readback-and-stamp half becomes stamp-image, and
applying the tag set moves to the manifest work in a following commit.

--platform is passed to the label build as well as the main one. Without it
podman re-resolves FROM to the host architecture and quietly swaps an amd64
image in under the arm64 tag.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Fan the test path out over architecture

**Files:**
- Modify: `Makefile` — replace `test`/`test-variant` (`:211-242` in the original numbering; find them by name)

**Interfaces:**
- Consumes: `ARCH_TAG`, `REQUIRE_ARCH_SH`, `PLATFORM_$(ARCH)` from Task 2;
  `EXPECT_ARCH` from Task 1.
- Produces: targets `test`, `test-arch` (needs `ARCH`), `test-image` (needs
  `VARIANT` and `ARCH`). `test-arch` has `build-arch` as a prerequisite.

- [ ] **Step 1: Replace `test` and `test-variant`**

Keep the existing three-checks comment block above `test` unchanged. Replace the
`test` and `test-variant` recipes with:

```make
test:
	@grep -q '$(TELEPORT_VERSION)' README.md || { \
	  echo "FAIL: README.md does not mention $(TELEPORT_VERSION); the version pin" >&2; \
	  echo "      has three copies (Containerfile, Makefile, README.md) and this" >&2; \
	  echo "      is the one nothing else cross-checks -- update README.md in the" >&2; \
	  echo "      same commit as any version bump." >&2; \
	  exit 1; \
	}
	@$(MAKE) --no-print-directory test-arch ARCH=amd64
	@$(MAKE) --no-print-directory test-arch ARCH=arm64

# build-arch is a prerequisite rather than something `test` depends on, so that
# a CI runner can say `make test-arch ARCH=arm64` and get the build for free.
# ARCH is a command-line variable in that invocation, so it reaches the
# prerequisite too.
test-arch: build-arch
	@set -eu; $(REQUIRE_ARCH_SH)
	@$(MAKE) --no-print-directory test-image VARIANT=tsh   ARCH=$(ARCH)
	@$(MAKE) --no-print-directory test-image VARIANT=admin ARCH=$(ARCH)

test-image:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; $(REQUIRE_ARCH_SH)
	@set -eu; \
	expected="LicenseRef-Teleport-Community-Edition"; \
	actual=$$($(PODMAN) image inspect --format '{{index .Config.Labels "org.opencontainers.image.licenses"}}' $(LOCAL_IMAGE):$(ARCH_TAG)); \
	[ "$$actual" = "$$expected" ] || { \
	  echo "FAIL: $(VARIANT)/$(ARCH): org.opencontainers.image.licenses label is '$$actual', expected '$$expected'" >&2; \
	  exit 1; \
	}
	@set -eu; \
	expected="$(DESC_$(VARIANT))"; \
	actual=$$($(PODMAN) image inspect --format '{{index .Config.Labels "org.opencontainers.image.description"}}' $(LOCAL_IMAGE):$(ARCH_TAG)); \
	[ "$$actual" = "$$expected" ] || { \
	  echo "FAIL: $(VARIANT)/$(ARCH): org.opencontainers.image.description label is '$$actual', expected '$$expected'" >&2; \
	  echo "      (expected the pinned version $(TELEPORT_VERSION) interpolated into it)" >&2; \
	  exit 1; \
	}
	$(PODMAN) run --rm --platform $(PLATFORM_$(ARCH)) -v ./test:/apps:ro,z \
	  -e EXPECT_VERSION=$(TELEPORT_VERSION) \
	  -e EXPECT_TCTL=$(EXPECT_TCTL_$(VARIANT)) \
	  -e EXPECT_ARCH=$(ARCH) \
	  $(LOCAL_IMAGE):$(ARCH_TAG) sh /apps/smoke.sh
```

Note the two failure messages now name `$(VARIANT)/$(ARCH)` rather than just the
variant — with four images in play, "admin" alone no longer identifies one.

- [ ] **Step 2: Test one architecture**

```bash
make test-arch ARCH=amd64
```

Expected: PASS for both variants, each printing `architecture: amd64`.

- [ ] **Step 3: Test the emulated architecture**

```bash
make test-arch ARCH=arm64
```

Expected: PASS for both variants, each printing `architecture: arm64`. This is
the run that proves the emulated image is genuinely `arm64` end to end — the
binary executes under QEMU and reports the pinned version.

- [ ] **Step 4: Prove the arch assertion has teeth**

Deliberately mislabel a run:

```bash
podman run --rm --platform linux/amd64 -v ./test:/apps:ro,z \
  -e EXPECT_VERSION=18.10.4 -e EXPECT_TCTL=no -e EXPECT_ARCH=arm64 \
  localhost/teleport-client:latest-amd64 sh /apps/smoke.sh
```

Expected: exit 1, `FAIL: image is amd64, expected arm64`.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "test: smoke-test every (variant, architecture) pair

test-image checks one image's labels and runs the smoke test inside it with
EXPECT_ARCH set; test-arch does both variants for one architecture and takes
build-arch as a prerequisite, so a CI runner gets the build for free from
`make test-arch ARCH=arm64`.

Failure messages now name variant/arch: with four images in play the variant
alone no longer identifies which one failed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Assemble the manifest lists

The ten canonical names become manifest lists over the four arch images. This is
where `TAG_SET_SH` comes back into use, unchanged.

**Files:**
- Modify: `Makefile` — add `MANIFEST_SRC` near `REGISTRY` (`:30`), add `manifests` and `manifest-variant` after the `stamp-image` target, replace `clean`

**Interfaces:**
- Consumes: `TAG_SET_SH` (unchanged), `READ_VERSION`, `BASE_TAG_$(VARIANT)`.
- Produces:
  - `MANIFEST_SRC` — defaults to `$(LOCAL_IMAGE)`; CI overrides with
    `$(REGISTRY)/$(IMAGE)`
  - `manifests` — both variants; takes optional `VERSION`
  - `manifest-variant` — one variant; requires `VARIANT`, requires `VERSION`

- [ ] **Step 1: Add `MANIFEST_SRC`**

After the `REGISTRY ?=` block (`Makefile:30`), add:

```make
# Where manifest-variant looks for the images a list will reference. Locally
# they are in local storage, which is the default. In CI each architecture is
# built and pushed by a different runner, so the members exist only in the
# registry and the manifest job passes MANIFEST_SRC=$(REGISTRY)/$(IMAGE).
#
# This is one of exactly two things that differ between a local build and a CI
# build (the other is where VERSION comes from), and it is a parameter rather
# than a branch on purpose: same target, same TAG_SET_SH, one input (D15).
MANIFEST_SRC ?= $(LOCAL_IMAGE)
```

- [ ] **Step 2: Add the manifest targets**

After `stamp-image`, add:

```make
# The five names a variant carries are manifest lists over the two arch images
# (D13/D14). VERSION is required rather than read here: the CI manifest job has
# no local image to inspect and receives it as a job output from the build job,
# which read it back off the image exactly as `manifests` does below. Either
# way no hand-typed version reaches the tag derivation, which is what D9's
# readback rule protects.
manifests:
	@set -eu; \
	v="$(VERSION)"; \
	[ -n "$$v" ] || v="$(call READ_VERSION,tsh)"; \
	$(MAKE) --no-print-directory manifest-variant VARIANT=tsh   VERSION="$$v"; \
	$(MAKE) --no-print-directory manifest-variant VARIANT=admin VERSION="$$v"

# Both variants ship the same tsh out of the same tarball, so one version covers
# both lists -- the same reason TAG_SET_SH has only ever taken a single $version
# and tag derivation reads tsh rather than tctl.
#
# A name may already exist as a plain image from a build that predates this
# scheme, or as a list from a previous run. Both are cleared first: `manifest
# create` fails on an existing name, and the manifest check has to come first
# because `podman image exists` is true for a list too.
manifest-variant:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; \
	version="$(VERSION)"; \
	[ -n "$$version" ] || { \
	  echo "ERROR: manifest-variant needs VERSION=X.Y.Z. Run 'make manifests', which reads it back off the built image." >&2; \
	  exit 1; \
	}; \
	$(TAG_SET_SH); \
	for t in $$tags; do \
	  if $(PODMAN) manifest exists "$(LOCAL_IMAGE):$$t" 2>/dev/null; then \
	    $(PODMAN) manifest rm "$(LOCAL_IMAGE):$$t" >/dev/null; \
	  elif $(PODMAN) image exists "$(LOCAL_IMAGE):$$t" 2>/dev/null; then \
	    $(PODMAN) rmi -f "$(LOCAL_IMAGE):$$t" >/dev/null; \
	  fi; \
	  $(PODMAN) manifest create "$(LOCAL_IMAGE):$$t" >/dev/null; \
	  $(PODMAN) manifest add "$(LOCAL_IMAGE):$$t" "$(MANIFEST_SRC):$(BASE_TAG_$(VARIANT))-amd64" >/dev/null; \
	  $(PODMAN) manifest add "$(LOCAL_IMAGE):$$t" "$(MANIFEST_SRC):$(BASE_TAG_$(VARIANT))-arm64" >/dev/null; \
	done; \
	echo "Manifest lists for $(VARIANT) over amd64+arm64: $$tags"
```

Single quotes around `make manifests` in that error message, not backticks — the
string reaches the shell inside a double-quoted `echo`, where backticks would be
command substitution.

- [ ] **Step 3: Teach `clean` about manifest lists**

`podman rmi` does not remove a manifest list. Replace the `clean` recipe (keep
the existing comment block, amending its first line to say "the ten lists and
four arch images this repo applies"):

```make
clean:
	@set -eu; \
	names=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -z "$$names" ]; then echo "nothing to clean"; exit 0; fi; \
	for n in $$names; do \
	  if $(PODMAN) manifest exists "$$n" 2>/dev/null; then \
	    $(PODMAN) manifest rm "$$n" >/dev/null; \
	  else \
	    $(PODMAN) rmi -f "$$n" >/dev/null; \
	  fi; \
	done; \
	echo "Removed: $$names"
```

This rests on `podman images` listing manifest lists alongside images, which was
checked on podman 5.8.1 while writing this plan (`podman manifest create
localhost/plan-probe` then `podman images` — the list appears as
`localhost/plan-probe:latest`). `podman manifest exists` was confirmed the same
way: it is a real subcommand and exits 1 silently on an unknown name, which is
what the `if` above relies on.

- [ ] **Step 4: Build everything and inspect a list**

```bash
make build
```

Expected: four image builds (the `arm64` pair from cache if Task 2/3 already
built them), then two lines like
`Manifest lists for tsh over amd64+arm64: latest 18 18.10 18.10.4 tsh`.

```bash
podman manifest inspect localhost/teleport-client:latest
```

Expected: a `manifests` array with two entries, `platform.architecture` `amd64`
and `arm64`, both `os: linux`.

```bash
podman manifest inspect localhost/teleport-client:18.10.4-admin
```

Expected: the same two-entry shape, and the digests must match those in
`podman manifest inspect localhost/teleport-client:admin` — the five names of a
variant are five names for one list's contents.

Check the missing-`VERSION` guard:

```bash
make manifest-variant VARIANT=tsh
```

Expected: exit 1 with the `needs VERSION=X.Y.Z` message, and no backtick
weirdness in the output. Fix the quoting if the shell mangled it.

- [ ] **Step 5: Verify `clean` removes everything**

```bash
podman images --format '{{.Repository}}:{{.Tag}}' | grep -c teleport-client
```

Expected: `14` (ten lists plus four arch images).

```bash
make clean
podman images --format '{{.Repository}}:{{.Tag}}' | grep teleport-client
```

Expected: no output.

Then rebuild for the next task:

```bash
make build
```

- [ ] **Step 6: Commit**

```bash
git add Makefile
git commit -m "feat: assemble the ten tags as manifest lists over both arches

The five names a variant carries stop being aliases of one image and become
manifest lists over its amd64 and arm64 members. TAG_SET_SH is unchanged --
it still derives the same names from one version, which is the point of having
defined the scheme in one place.

MANIFEST_SRC is where the members are looked for: local storage by default, and
the registry in CI, where the two architectures were built by different runners
and only meet there. It is a parameter rather than a branch so local and CI run
the same recipe.

clean learns that podman rmi does not remove a manifest list.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Publish the arch images and the lists

**Files:**
- Modify: `Makefile` — replace `push`/`push-variant`, update `help`

**Interfaces:**
- Consumes: everything from Tasks 2–4.
- Produces: targets `push`, `push-arch` (needs `ARCH`), `push-image` (needs
  `VARIANT` and `ARCH`), `push-manifests`, `push-manifest-variant` (needs
  `VARIANT`).

- [ ] **Step 1: Replace `push` and `push-variant`**

Replace the `push` comment block and both recipes with:

```make
# Mirror the four architecture images and then the ten lists to $(REGISTRY).
# Depends on test, so a smoke-test failure blocks the publish.
#
# `manifests` is called here and not left to `build`, because `test` does not
# call it: `test-arch` takes `build-arch` as its prerequisite, which stops at
# the four architecture images. Without this line `push` would try to push
# lists nothing had created. `test` must NOT call it instead -- a
# single-architecture CI runner has only its own arch's images and cannot
# assemble a two-member list, which is the whole reason the split exists.
# `manifests` clears and recreates each name, so calling it twice is safe.
#
# Not atomic, and now in one more sense than before: the arch images go up
# first and the lists that reference them second, so an interruption between
# the two leaves the lists pointing at the previous members while the arch tags
# are already new. Re-running repairs it. This is the failure mode D15 names,
# and it is why the workflow does not cancel in-progress runs on master.
push: test
	@$(MAKE) --no-print-directory push-arch ARCH=amd64
	@$(MAKE) --no-print-directory push-arch ARCH=arm64
	@$(MAKE) --no-print-directory manifests
	@$(MAKE) --no-print-directory push-manifests

push-arch:
	@set -eu; $(REQUIRE_ARCH_SH)
	@$(MAKE) --no-print-directory push-image VARIANT=tsh   ARCH=$(ARCH)
	@$(MAKE) --no-print-directory push-image VARIANT=admin ARCH=$(ARCH)

# Only the base tag carries an architecture suffix (D14), so this pushes one
# name per (variant, arch) -- four in total, not twenty.
push-image:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; $(REQUIRE_ARCH_SH)
	@echo "Pushing $(REGISTRY)/$(IMAGE):$(ARCH_TAG)"
	$(PODMAN) push "$(LOCAL_IMAGE):$(ARCH_TAG)" "$(REGISTRY)/$(IMAGE):$(ARCH_TAG)"

push-manifests:
	@$(MAKE) --no-print-directory push-manifest-variant VARIANT=tsh   VERSION="$(VERSION)"
	@$(MAKE) --no-print-directory push-manifest-variant VARIANT=admin VERSION="$(VERSION)"

# --all pushes the member images alongside the list. In CI they are already
# there, having been pushed by the two build jobs, and re-pushing is a no-op on
# unchanged blobs; locally it is what makes `make push` work on its own without
# a separate member push. Same flag both ways, so the two halves stay identical.
#
# VERSION is optional here and required in manifest-variant, for the same reason
# in both: the CI manifest job has no local image to inspect, so it passes the
# value the build job read back off the image. Locally the fallback readback is
# free -- an inspect of the label stamp-image wrote, not a container start, and
# of the host-architecture member so no emulation is needed just to publish.
push-manifest-variant:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; \
	version="$(VERSION)"; \
	[ -n "$$version" ] || version="$(call READ_VERSION,$(VARIANT))"; \
	[ -n "$$version" ] || { \
	  echo "ERROR: push-manifest-variant found no local image to read the version off; pass VERSION=X.Y.Z" >&2; \
	  exit 1; \
	}; \
	$(TAG_SET_SH); \
	for t in $$tags; do \
	  echo "Pushing $(REGISTRY)/$(IMAGE):$$t (manifest list)"; \
	  $(PODMAN) manifest push --all "$(LOCAL_IMAGE):$$t" "docker://$(REGISTRY)/$(IMAGE):$$t"; \
	done
```

- [ ] **Step 2: Update `help`**

Replace the `help` recipe's body with:

```make
help:
	@echo "Targets:"
	@echo "  build   Build both variants for both architectures and assemble the manifest lists"
	@echo "  test    Smoke-test all four images (builds first)"
	@echo "  push    Publish the four arch tags and the ten lists to $(REGISTRY)/$(IMAGE) (builds and tests first)"
	@echo "  clean   Remove every tag and manifest list this repo applies"
	@echo
	@echo "Variants (one Containerfile, gated on the INCLUDE_TCTL build arg):"
	@echo "  tsh     tsh alone     -> latest, 18, 18.10, $(TELEPORT_VERSION), tsh"
	@echo "  admin   tsh and tctl  -> tctl, admin, 18-admin, 18.10-admin, $(TELEPORT_VERSION)-admin"
	@echo
	@echo "Architectures: amd64, arm64. Those ten names are manifest lists over"
	@echo "both; the images themselves also carry latest-<arch> and admin-<arch>."
	@echo "This host is $(HOST_ARCH); the other is built under emulation."
	@echo
	@echo "Each target does everything. Narrow with ARCH= on the -arch targets"
	@echo "(build-arch, test-arch, push-arch), or with both VARIANT= and ARCH= on"
	@echo "the -image targets (build-image, test-image, push-image)."
	@echo
	@echo "Pinned Teleport version: $(TELEPORT_VERSION)"
	@echo "Bumping it means editing the Makefile, the two per-arch digests and"
	@echo "TELEPORT_VERSION in the Containerfile, and README.md."
```

- [ ] **Step 3: Verify without publishing**

`make push` needs registry credentials, so check the plan of action rather than
running it:

```bash
make -n push 2>&1 | grep -E 'podman (push|manifest push)'
```

Expected: four plain `podman push` lines — one per variant per architecture,
each its own recipe line — and two `manifest push --all` occurrences.

**Two, not ten**, and the difference is the point: `push-image` is invoked four
separate times, so `make -n` prints its recipe four times, but
`push-manifest-variant`'s five pushes happen inside a `for t in $$tags` loop,
which `-n` prints as text rather than unrolling. Two variants, two printed
loops. (`make -n` does recurse into `$(MAKE)` lines — that is why the four are
four and not one.)

```bash
make -n push 2>&1 | grep -c 'podman push'
make -n push 2>&1 | grep -c 'manifest push --all'
```

Expected: `4` and `2`.

Confirm the destinations are right:

```bash
make -n push 2>&1 | grep 'manifest push --all' | head -3
```

Expected: destinations of the form
`docker://docker.io/pdutton/teleport-client:latest`, and sources of the form
`localhost/teleport-client:latest`.

- [ ] **Step 4: Check `help` and the guards**

```bash
make help
make push-image VARIANT=tsh
make push-arch
```

Expected: help renders with the architecture paragraph; both guarded calls exit
1 with the `ARCH=amd64 or ARCH=arm64` message.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat: publish four arch tags and ten manifest lists

push-image sends one arch-suffixed image per (variant, arch); the suffix goes on
the base tag only, so this is four names rather than twenty (D14).
push-manifest-variant then sends the five lists with --all, which carries the
members too -- a no-op against a registry that already has them from CI's build
jobs, and the reason a local `make push` needs no separate member step.

The publish is no longer a single act: arch images go up before the lists that
reference them, so an interruption between the two leaves the lists stale until
a re-run. Named in the comment rather than papered over.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Build each architecture on its own runner

**Files:**
- Modify: `.github/workflows/build.yml` — matrix the `build` job, add a `manifest` job, repoint `description`

**Interfaces:**
- Consumes: `test-arch`, `push-arch`, `manifests`, `push-manifests`,
  `MANIFEST_SRC`, `VERSION` from Tasks 2–5.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Matrix the build job over architecture**

Replace the `build` job's `name`/`runs-on`/`timeout-minutes` header and its
existing comment with:

```yaml
jobs:
  build:
    name: build (${{ matrix.arch }})
    # One runner per architecture rather than one runner emulating both (D15).
    # ubuntu-24.04-arm is free for public repositories, which this is (M6), so
    # arm64 costs nothing and pull requests get native arm64 coverage they did
    # not have before. A local `make build` still does both under qemu; the
    # Makefile targets invoked are the same ones either way.
    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: amd64
            runner: ubuntu-latest
          - arch: arm64
            runner: ubuntu-24.04-arm
    runs-on: ${{ matrix.runner }}
    # Two variants per runner, and the variants diverge at exactly the layer
    # podman's cache would otherwise reuse, so the 217 MB tarball is still
    # pulled twice per job. Both architectures now run in parallel, so this is
    # the same wall-clock budget as the single job it replaces.
    timeout-minutes: 30
    outputs:
      version: ${{ steps.version.outputs.version }}
```

- [ ] **Step 2: Replace the two build/push steps**

Leave `actions/checkout@v7` and the whole `Ensure podman` step exactly as they
are. Replace the `Build and smoke-test`, `Log in to Docker Hub` and
`Build, smoke-test, and push` steps with:

```yaml
      # Publishing happens only from master. A dispatch against another branch
      # still builds and smoke-tests, so a branch can be put through CI, but it
      # must never overwrite the shared mutable tags with unreviewed code. This
      # condition is the exact negation of the publish condition below.
      - name: Build and smoke-test
        if: github.event_name == 'pull_request' || github.ref != 'refs/heads/master'
        run: make PODMAN="$PODMAN" AWK="$AWK" test-arch ARCH=${{ matrix.arch }}

      - name: Log in to Docker Hub
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        env:
          DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
        run: printf '%s' "$DOCKERHUB_TOKEN" | podman login docker.io -u "$DOCKERHUB_USERNAME" --password-stdin

      # One make invocation with two goals, run in order: test-arch takes
      # build-arch as a prerequisite, and push-arch deliberately does not depend
      # on test-arch, so this builds, smoke-tests, then publishes this
      # architecture's two images. The manifest lists are not this job's to
      # write -- the other architecture's images do not exist here.
      - name: Build, smoke-test, and push this architecture
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        run: make PODMAN="$PODMAN" AWK="$AWK" test-arch push-arch ARCH=${{ matrix.arch }}

      # The manifest job has no image to read the version off, so it comes from
      # here -- read back out of the built image exactly as a local `make
      # manifests` would, so no hand-typed version reaches the tag derivation
      # (D9, D15).
      #
      # BOTH legs write it, deliberately. Matrix legs sharing an output key are
      # last-writer-wins by completion order, and a leg that skips this step
      # still evaluates the job-level `outputs:` expression -- to the empty
      # string. Gating this on one architecture would therefore let the other
      # leg overwrite a good version with nothing whenever it finished last.
      # Having both write is what makes the race harmless: `test-arch` has
      # already asserted each image's `tsh version` equals TELEPORT_VERSION
      # before this runs, so the two legs write the same string by construction.
      - name: Report the built version
        id: version
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        run: |
          tag="localhost/teleport-client:latest-${{ matrix.arch }}"
          v=$("$PODMAN" image inspect \
            --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
            "$tag")
          test -n "$v" || { echo "ERROR: no version label on $tag" >&2; exit 1; }
          echo "version=$v" >> "$GITHUB_OUTPUT"
          echo "Built version $v"
```

- [ ] **Step 3: Add the manifest job**

Insert between the `build` job and the `description` job:

```yaml
  # The two architectures were built by different runners and only meet in the
  # registry, so the lists are assembled from registry references
  # (MANIFEST_SRC) rather than from local storage. Same Makefile targets a local
  # `make push` runs -- only the two inputs D15 names differ.
  manifest:
    name: manifest lists
    runs-on: ubuntu-latest
    needs: build
    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
    # No image build here: this pulls two manifests and pushes ten small lists.
    timeout-minutes: 15

    steps:
      - uses: actions/checkout@v7

      - name: Ensure podman
        run: |
          if ! command -v podman >/dev/null; then
            sudo apt-get update
            sudo apt-get install -y podman
          fi
          PODMAN="$(command -v podman)"
          AWK="$(command -v awk)"
          test -n "$PODMAN" || { echo "ERROR: podman not on PATH after install" >&2; exit 1; }
          test -n "$AWK"    || { echo "ERROR: awk not on PATH" >&2; exit 1; }
          echo "PODMAN=$PODMAN" >> "$GITHUB_ENV"
          echo "AWK=$AWK"       >> "$GITHUB_ENV"

      - name: Log in to Docker Hub
        env:
          DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
        run: printf '%s' "$DOCKERHUB_TOKEN" | podman login docker.io -u "$DOCKERHUB_USERNAME" --password-stdin

      - name: Assemble and push the manifest lists
        env:
          VERSION: ${{ needs.build.outputs.version }}
        run: |
          test -n "$VERSION" || { echo "ERROR: the build job reported no version" >&2; exit 1; }
          make PODMAN="$PODMAN" AWK="$AWK" manifests \
            VERSION="$VERSION" MANIFEST_SRC=docker.io/pdutton/teleport-client
          make PODMAN="$PODMAN" AWK="$AWK" push-manifests VERSION="$VERSION"
```

`VERSION` is passed to both invocations because this runner has no local image
for the fallback readback in `push-manifest-variant` to inspect. `MANIFEST_SRC`
is spelled out rather than reusing `$(REGISTRY)/$(IMAGE)` because the workflow
cannot expand make variables; if `REGISTRY` is ever changed in the Makefile,
this line has to change with it.

- [ ] **Step 4: Repoint the description job**

In the `description` job, change:

```yaml
    needs: build
```

to:

```yaml
    needs: manifest
```

and amend its leading comment to say the page is synced after the lists are
published, not after the images.

- [ ] **Step 5: Validate the workflow, and rehearse the manifest job locally**

Check the YAML parses and the job graph is what you expect:

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/build.yml')); print(list(d['jobs'])); print({k: v.get('needs') for k,v in d['jobs'].items()})"
```

Expected: `['build', 'manifest', 'description']` and
`{'build': None, 'manifest': 'build', 'description': 'manifest'}`.

Now reproduce the manifest job's situation — no local images at all, version
supplied from outside — which is the part of Task 6 that can be checked without
pushing to GitHub:

```bash
make clean
make manifests VERSION=18.10.4 MANIFEST_SRC=docker.io/pdutton/teleport-client
```

Expected: the ten lists are created from the *published* `latest-amd64` /
`admin-amd64` / `…-arm64` images. **This only works once a previous run has
published those four tags**, so on the very first pass it will fail with a
manifest-unknown error from the registry. That failure is informative, not a
defect: it confirms `MANIFEST_SRC` is being consulted and that the members are
genuinely fetched from the registry rather than local storage. Note it and move
on; the merge run is where this path first succeeds.

Then confirm the local path is unbroken and `VERSION` propagates:

```bash
make build
make -n push-manifests VERSION=18.10.4 | grep -c 'manifest push --all'
```

Expected: `2` — one printed `for` loop per variant; `make -n` does not unroll
it. Confirm `VERSION` propagated by checking it appears in the printed recipe:

```bash
make -n push-manifests VERSION=18.10.4 | grep -o 'version="18.10.4"' | head -1
```

Expected: one match.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build each architecture on a runner of that architecture

The build job gains the matrix D11 said it did not have -- over architecture
rather than variant. ubuntu-24.04-arm is free for public repositories, so arm64
costs nothing and pull requests get native arm64 coverage.

A third job assembles the ten manifest lists. It has to: the two architectures
are built by different runners and only meet in the registry, which is what
MANIFEST_SRC is for. The version it needs comes from the build job as an
output, read back off the image rather than typed, so the readback rule holds
across the job boundary. Both legs report it: matrix outputs are last-writer-wins
and a leg that skips the step still writes an empty string, so gating it on one
architecture would let the other blank it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Documentation

Four files claim single-arch behaviour or describe targets that no longer exist.

**Files:**
- Modify: `README.md:346-351` (the whole `## Planned` section)
- Modify: `DOCKERHUB-OVERVIEW.md:72-88` (the `## Tags` section)
- Modify: `CLAUDE.md` (build/test block, Variants section, Testing section, Publishing section)
- Modify: `docs/superpowers/specs/2026-08-12-teleport-client-image-design.md` (the Out of scope third-architecture list)

**Interfaces:** none.

- [ ] **Step 1: `README.md` — replace `## Planned`**

That section's only content is the multi-arch bullet, so the heading goes with
it. Replace lines 346–351 with:

```markdown
## Architectures

Published for `linux/amd64` and `linux/arm64`. Every tag in the table above is a
manifest list, so `podman pull …:latest` (or `docker pull`) resolves to the
architecture you are on with nothing to specify.

Four extra tags name a single architecture directly — `latest-amd64`,
`latest-arm64`, `admin-amd64`, `admin-arm64`. They exist because CI builds each
architecture on a runner of that architecture and the two images have to meet in
the registry before a list can reference them. Pull one if you are deliberately
testing the other architecture's image; otherwise use the plain tags.

`make build` produces both architectures on one machine, emulating the foreign
one through `binfmt_misc`. On Debian and Ubuntu that needs `qemu-user-static`
installed; on Fedora, `qemu-user-static` plus `systemd-binfmt`. Check it is
registered with:

    cat /proc/sys/fs/binfmt_misc/qemu-aarch64

To build only your own architecture, narrow it: `make build-arch ARCH=amd64`.
```

Check whether the README's tag table sits above this point; if the phrase "the
table above" does not match the document's actual order, say "in the Tags
section" instead. Verify by reading the section headings:

```bash
grep -n '^## ' README.md
```

- [ ] **Step 2: `DOCKERHUB-OVERVIEW.md` — extend `## Tags`**

After the existing ten-row table (`:88`), add:

```markdown
Every tag above is a **manifest list** covering `linux/amd64` and `linux/arm64`,
so a plain `docker pull pdutton/teleport-client` gets the right one
automatically.

Four more tags name one architecture directly, for when you want to pull the
other one deliberately:

| Tag | Contents | Architecture |
|---|---|---|
| `latest-amd64` | `tsh` | `linux/amd64` |
| `latest-arm64` | `tsh` | `linux/arm64` |
| `admin-amd64` | `tsh` + `tctl` | `linux/amd64` |
| `admin-arm64` | `tsh` + `tctl` | `linux/arm64` |

These are the images the lists point at. Prefer the plain tags unless you have a
specific reason not to.
```

- [ ] **Step 3: `CLAUDE.md` — bring four sections up to date**

In the **Build and test** block, replace the command list with:

```bash
make help    # lists every user-facing target and the pinned version
make build   # builds both variants for both architectures, assembles the ten manifest lists
make test    # builds, then runs test/smoke.sh inside each of the four images
make clean   # removes this repo's ten lists and four arch images
make push    # builds, tests, then publishes every tag (needs registry credentials)
```

and replace the parenthetical about `tag` — that target no longer exists — with:

```
(`make help` doesn't enumerate the `-image` targets individually; they're real
and directly invocable (`make build-image VARIANT=admin ARCH=arm64`), and the
help text says how to reach them rather than listing all six.)
```

Add a new section after **Variants**:

```markdown
## Architectures

`amd64` and `arm64`, from one `Containerfile` (D13). It needs no architecture
knowledge from the Makefile: its `case "$(uname -m)"` reports `aarch64` both
under qemu-user emulation and on a native `arm64` runner, and it already pinned
a digest per architecture before any of this existed.

Targets come in three widths, and this is the whole shape of the Makefile:

| Width | Inputs | Scope |
|---|---|---|
| `build` `test` `push` | none | 2 variants × 2 architectures, then the lists |
| `build-arch` `test-arch` `push-arch` | `ARCH` | both variants, one architecture — what one CI runner does |
| `build-image` `test-image` `push-image` `stamp-image` | `VARIANT` `ARCH` | one image |

The ten names of D9/D12 are manifest lists now; the images themselves carry only
`<base>-<arch>`. `--platform` is passed to **both** `podman build` calls in
`build-image`/`stamp-image` — the label build re-resolves `FROM` to the host
architecture without it and silently swaps an `amd64` image in under the `arm64`
tag, which is exactly what `EXPECT_ARCH` in the smoke test exists to catch.

Local builds emulate the foreign architecture; CI builds each natively on its
own runner (D15). Only two things differ between them, and both are parameters
rather than branches: `MANIFEST_SRC` (local storage vs the registry, since CI's
two architectures only meet there) and where `VERSION` comes from (a local
readback vs a job output carrying the same readback).
```

In **Testing**, add after the `EXPECT_TCTL` paragraph:

```markdown
`EXPECT_ARCH` is validated against exactly `amd64`/`arm64` for the same reason,
and asserts `uname -m` inside the running image. It is the one assertion that
catches a `--platform` gone missing from one of the two builds — an `amd64`
image published under an `arm64` name passes every other check in the file.
```

In **Publishing**, replace the "ten-tag scheme" paragraph's first sentence so it
reads `TAG_SET_SH` is expanded by `manifest-variant` and `push-manifest-variant`
(not `tag-variant`/`push-variant`), and add:

```markdown
Fourteen names go up, not ten: the ten of `TAG_SET_SH` as manifest lists, plus
`latest-amd64`, `latest-arm64`, `admin-amd64` and `admin-arm64` as plain images
(D14). The suffix goes on the base tag only. The publish is two-phase — arch
images first, then the lists referencing them — so an interruption between them
leaves the lists stale until a re-run.
```

- [ ] **Step 4: Fix the spec's third-architecture checklist**

The Out of scope bullet added with D13–D15 lists what a third architecture would
need but omits two places. In
`docs/superpowers/specs/2026-08-12-teleport-client-image-design.md`, change:

```
  later is mechanical: a `case` arm and a digest `ARG` in the `Containerfile`, a
  row in the arch block and a name in `REQUIRE_ARCH_SH` in the Makefile, and a
  runner or emulator that can build it.
```

to:

```
  later is mechanical: a `case` arm and a digest `ARG` in the `Containerfile`, a
  row in the arch block, a name in `REQUIRE_ARCH_SH`, a `podman manifest add`
  line in `manifest-variant` and one line in each plain target in the Makefile,
  and a runner or emulator that can build it.
```

- [ ] **Step 5: Verify the docs against the code**

The version grep in `make test` reads `README.md`, so confirm nothing was lost:

```bash
grep -c '18.10.4' README.md
```

Expected: at least 1.

Check no doc still promises single-arch or names a deleted target:

```bash
grep -rn 'no multi-arch manifest\|tag-variant\|build-variant\|test-variant\|push-variant' \
  README.md DOCKERHUB-OVERVIEW.md CLAUDE.md
```

Expected: no output. (The spec keeps its historical references to
`tag-variant`/`push-variant` inside D11 and D12 — those are records of what was
decided then, and the D15 annotation is what updates them. Do not rewrite them.)

Confirm the help text matches the real target list:

```bash
make help
make -qp 2>/dev/null | grep -E '^(build|test|push)(-arch|-image)?:' | sort -u
```

- [ ] **Step 6: Commit**

```bash
git add README.md DOCKERHUB-OVERVIEW.md CLAUDE.md docs/superpowers/specs/2026-08-12-teleport-client-image-design.md
git commit -m "docs: describe the images as multi-arch

README's Planned section held exactly one bullet -- multi-arch -- so it is
replaced by an Architectures section rather than emptied. DOCKERHUB-OVERVIEW
said nothing about architecture at all, which under-warned arm64 pullers before
and would misdescribe the lists now; it gains the four arch tags and a statement
that the ten are lists.

CLAUDE.md's build block named targets that no longer exist and its Variants
section described a one-dimensional fan-out. The spec's third-architecture
checklist was missing two of the places that would need editing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Full verification

Nothing new is written here. This is the end-to-end pass that must succeed
before the branch is offered for merge.

**Files:** none.

- [ ] **Step 1: Clean-room build and test**

```bash
make clean
make build
make test
```

**About 3 minutes from a cleared cache.** `make build` produces the four images
and the ten lists; `make test` then re-enters `build-arch` (cached, fast) and
runs the four smoke tests. Expected: four smoke tests, each printing its own `architecture:`
line — two `amd64`, two `arm64` — and four `PASS` lines.

`make test` alone is not enough here, and the reason is worth knowing: `test`
fans out to `test-arch`, which stops at `build-arch` and the four architecture
images. It never assembles the lists — deliberately, since a single-architecture
CI runner could not. So a `clean` followed by `test` alone leaves four names,
not fourteen, and Step 2 below would fail.

- [ ] **Step 2: Confirm the published shape**

```bash
podman images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^localhost/teleport-client:' | sort
```

Expected: exactly fourteen names — the ten canonical ones plus `latest-amd64`,
`latest-arm64`, `admin-amd64`, `admin-arm64`.

Anchor the match to `localhost/`. A bare `grep teleport-client` also catches
registry-qualified images in local storage (a `docker.io/pdutton/teleport-client`
tag left by an earlier pull or push) and reports fifteen — those are correctly
outside `clean`'s scope, which is `localhost`-anchored for exactly this reason.

```bash
for t in latest tsh 18 18.10 18.10.4 admin tctl 18-admin 18.10-admin 18.10.4-admin; do
  printf '%-16s ' "$t"
  podman manifest inspect "localhost/teleport-client:$t" \
    | grep -c '"architecture"'
done
```

Expected: `2` for every one of the ten.

- [ ] **Step 3: Confirm the two variants really differ, per architecture**

```bash
podman run --rm --platform linux/arm64 localhost/teleport-client:admin-arm64 tctl version
podman run --rm --platform linux/arm64 localhost/teleport-client:latest-arm64 sh -c 'command -v tctl || echo "tctl absent, correct"'
```

Expected: the pinned version from the first, `tctl absent, correct` from the
second. The smoke test asserts both, but running it by hand on the emulated
architecture is worth doing once.

- [ ] **Step 4: Dry-run the publish**

```bash
make -n push 2>&1 | grep -cE 'podman push'
make -n push 2>&1 | grep -c 'manifest push --all'
make -n push 2>&1 | grep -c 'make --no-print-directory manifests'
```

Expected: `4`, `2`, and `1`.

The first two are `make -n` artefacts — see Task 5 Step 3 for why the second is
two rather than ten (`make -n` prints the `for` loop, it does not unroll it).

**The third is the one that matters.** `push` must assemble the lists before it
pushes them: `test` stops at the four architecture images, so without a
`manifests` call in `push` the pushes would target lists nothing had created —
and the first two counts would still read `4` and `2`, which is exactly how that
bug survived six task reviews. A zero here means `push` is broken on a clean
checkout while every other check passes.

Count the `$(MAKE) manifests` invocation, not `podman manifest create`. The
`create` calls live inside `manifest-variant`'s `for t in $$tags` loop, so
`make -n` prints two of them — one per variant — not ten, for the same reason
`manifest push --all` prints two. Asserting `10` there fails against correct
code.

- [ ] **Step 5: Review the whole diff**

```bash
git -C /home/pdutton/projects/container-teleport/feature/multi-arch diff master --stat
git -C /home/pdutton/projects/container-teleport/feature/multi-arch diff master -- Containerfile
```

Expected: `Containerfile` shows **no diff at all** — that is D13's central
claim, and a change there means something went wrong.

- [ ] **Step 6: Push the branch and open a PR**

```bash
git -C /home/pdutton/projects/container-teleport/feature/multi-arch push -u origin feature/multi-arch
```

Then open a PR. **The PR run is the only real test of Task 6** — the `arm64`
runner, the matrix, and the job graph cannot be verified locally. Watch that
both `build (amd64)` and `build (arm64)` pass before merging. The `manifest` job
is master-only and will not run on the PR; it gets its first real exercise on
merge, so watch that run too and be ready to re-run it if the lists end up stale
(the failure mode D15 names).

---

## Notes for the implementer

**What "test" means here.** There is no unit-test suite and no lint step. `make
test` is the entire story: label checks from outside the image, then
`test/smoke.sh` inside it. Where this plan says "write the failing test", it
means "run the assertion against something it should reject and watch it not
reject it" — the smoke test's own invocation is the harness.

**Why the arm64 build runs emulated at all.** The `downloader` stage runs
`curl` and `tar` under QEMU on a 217 MB tarball. This was a deliberate choice
(D13): running that stage natively would mean replacing `uname -m` with
`TARGETARCH`, which is the load-bearing line in D2 and D6. Do not "optimise"
it — and note the cost is smaller than it looks, since a full cleared-cache
build of all four images measures around 3 minutes.

**If `podman manifest add` cannot reach a registry reference** in the CI manifest
job, the fallback is `podman manifest add` against
`docker://docker.io/pdutton/teleport-client:latest-amd64` with an explicit
transport. Try the plain reference first.

**Do not touch the sibling repos.** `container-ansible` and
`container-terraform` both list multi-arch under Planned. Porting this is
separate work in separate repos (D15, Scope).
