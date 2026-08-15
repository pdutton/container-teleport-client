IMAGE    ?= teleport-client

# The Teleport version this image pins. Written here AND as ARG
# TELEPORT_VERSION in the Containerfile, deliberately independent: this copy is
# only ever handed to the smoke test as EXPECT_VERSION, and is never passed as a
# --build-arg. If it were, the two could still not disagree -- but the
# assertion would still be meaningful: EXPECT_VERSION is checked against what
# the binary itself reports, which verifies the tarball at that URL really
# contains a `tsh` reporting that version and that the extraction pulled the
# right archive member. What the split buys is narrower and still real: it
# catches a human editing one file and not the other.
#
# So editing one alone does NOT break `podman build` -- the image builds fine --
# it breaks `make test`. That is the safety net working, not a bug. Bumping the
# pin means editing this, the ARG TELEPORT_VERSION and the two per-architecture
# ARG TELEPORT_SHA256_* digests in the Containerfile, and the version named in
# README.md (checked by `make test`, see below).
TELEPORT_VERSION := 18.10.4

# External tools, overridable: `make PODMAN=/usr/local/bin/podman build`
#
# Resolved rather than hardcoded, because these live in different places on
# different systems -- podman moved off /usr/bin on the GitHub runners mid-2026,
# and jq sits in /usr/bin on Debian, /usr/sbin on some merged-/usr layouts and
# /opt/homebrew/bin on macOS -- so any single absolute default is wrong
# somewhere common.
#
# `command -pv` and not `command -v`: -p searches the system's *default* PATH
# rather than the caller's. Every recipe here runs podman against images that
# get published, so which binary that name resolves to is a trust decision, and
# a PATH entry is not a trustworthy way to make it. The recipes must never fall
# back to a PATH lookup for the same reason -- an inherited PATH is exactly the
# thing being routed around, so an unfound tool is an error, never a bare name
# left for the shell to resolve later.
#
# A path passed in explicitly is different: that is a deliberate choice by
# whoever ran make, not an ambient one. CI uses it, because the runners keep
# podman outside the default PATH.
AWK_PATH    := $(shell command -pv awk)
PODMAN_PATH := $(shell command -pv podman)
JQ_PATH     := $(shell command -pv jq)

# Recursive (`?=`), so a missing tool fails when a recipe actually needs it
# rather than when make parses this file. `make help` and `make clean` should
# still work on a machine that has never installed jq, which only
# check-published uses.
AWK      ?= $(if $(AWK_PATH),$(AWK_PATH),$(error ERROR: awk not found in the default PATH ($(shell getconf PATH)); pass AWK=/path/to/awk))
PODMAN   ?= $(if $(PODMAN_PATH),$(PODMAN_PATH),$(error ERROR: podman not found in the default PATH ($(shell getconf PATH)); pass PODMAN=/path/to/podman))
JQ       ?= $(if $(JQ_PATH),$(JQ_PATH),$(error ERROR: jq not found in the default PATH ($(shell getconf PATH)); pass JQ=/path/to/jq))

# Registry the push target publishes to. Override to retarget:
# `make push REGISTRY=ghcr.io/pdutton`
#
# The account here must match the DOCKERHUB_USERNAME repository secret CI logs
# in with. If they disagree nothing fails early: `podman login` succeeds against
# the wrong account and the push 401s on its first tag.
REGISTRY ?= docker.io/pdutton

# Where manifest-variant looks for the images a list will reference. Locally
# they are in local storage, which is the default. In CI each architecture is
# built and pushed by a different runner, so the members exist only in the
# registry and the manifest job passes MANIFEST_SRC=$(REGISTRY)/$(IMAGE).
#
# This is one of exactly two things that differ between a local build and a CI
# build (the other is where VERSION comes from), and it is a parameter rather
# than a branch on purpose: same target, same TAG_SET_SH, one input (D15).
MANIFEST_SRC ?= $(LOCAL_IMAGE)

# Every local image reference goes through this, never a bare $(IMAGE). A bare
# short name can resolve to a non-localhost repo when that is the only match, so
# an unqualified reference on the highest-stakes line in this file -- the push
# source -- would depend on an implicit tie-break rather than on the name
# itself. `=` (recursive), not `:=`, so this still tracks an overridden IMAGE.
LOCAL_IMAGE = localhost/$(IMAGE)

# ---- variants ---------------------------------------------------------------
# Two images, one Containerfile, one build arg between them (D12):
#
#   tsh    the default -- tsh alone. Carries `latest`, `tsh`, and the bare
#          version tags.
#   admin  tsh and tctl. Carries `tctl`, `admin`, and the version tags with an
#          `-admin` suffix.
#
# Every per-variant *setting* is a row in this block, looked up from the recipes
# as $(<SETTING>_$(VARIANT)). The plain targets (build, test, push) each
# re-invoke make once per architecture, calling their `-arch` target twice; it
# is the `-arch` targets that re-invoke once per variant, calling the
# `-image` targets that do the actual work and require both VARIANT and ARCH
# to be set.
#
# Adding a third variant means adding a row to each table here, a branch to
# TAG_SET_SH, a name to REQUIRE_VARIANT_SH, and one line to each `-arch`
# target -- but no new recipe. The fan-out is written out rather than looped
# over a VARIANTS list on purpose: two literal lines survive `make -n`
# legibly and cannot swallow a non-zero exit the way a `for` loop in a
# recipe can.
INCLUDE_TCTL_tsh   := false
INCLUDE_TCTL_admin := true

# The tag each variant's build writes first; every later step reads the image
# back from it, and the architecture block below suffixes it with -$(ARCH) for
# the tag an actual build lands under.
BASE_TAG_tsh   := latest
BASE_TAG_admin := admin

# Passed to the smoke test, which asserts tctl is present for one variant and
# absent for the other -- the exclusion is contract in both directions.
EXPECT_TCTL_tsh   := no
EXPECT_TCTL_admin := yes

# org.opencontainers.image.description, asserted by `make test`. Built from
# shared halves so a version bump or a base-OS change cannot desync the two.
DESC_PREFIX := Teleport $(TELEPORT_VERSION) Community Edition client
DESC_SUFFIX := on Ubuntu 26.04
DESC_tsh    := $(DESC_PREFIX) (tsh) $(DESC_SUFFIX)
DESC_admin  := $(DESC_PREFIX) (tsh, tctl) $(DESC_SUFFIX)

# Only the admin build overrides the description on the command line. The tsh
# build deliberately does not: leaving it to the Containerfile's own LABEL keeps
# the D3 check meaningful, since `make test` then compares this file's copy
# against an independently written one. The admin string exists only here --
# LABEL cannot branch on a build arg -- so its check proves the override landed
# and interpolated the version, but has no second copy to disagree with.
DESC_LABEL_tsh   :=
DESC_LABEL_admin := --label 'org.opencontainers.image.description=$(DESC_admin)'

# ---- architectures ----------------------------------------------------------
# Two architectures, one Containerfile, one --platform flag between them (D13).
#
# The Containerfile needs no architecture knowledge from here and is not
# modified by any of this: its `case "$(uname -m)"` reports aarch64 both under
# the qemu-user registration this machine already has (M6) and on a native
# arm64 runner, so the same file is correct in both halves of D15.
#
# Same written-out fan-out rule as the variant block: two literal lines, no
# ARCHES list looped over in a recipe. Adding a third architecture means, in
# this file, a row here, a name in REQUIRE_ARCH_SH, a `podman manifest add` line
# in manifest-variant and one line in each plain target -- and outside it, a
# `case` arm plus a digest ARG in the Containerfile, both of test/smoke.sh's
# architecture `case` statements (the EXPECT_ARCH validation and the `uname -m`
# map, which reject an unrecognised value on purpose), and a matrix entry in
# .github/workflows/build.yml naming a runner that can build it.

# The architecture of the machine running make, in podman's naming rather than
# uname's. Three consumers: READ_VERSION below, which reads a version label back
# off the host-architecture member of a variant -- the one member that needs no
# emulation just to read a label, unlike the arch-suffixed builds, stamps and
# smoke tests this block also defines, which run under emulation for the
# non-host architecture on purpose -- `help`, which names it so the reader
# knows which of the two they get natively -- and the `manifests` recipe's error
# message, which names the image it failed to inspect.
HOST_ARCH := $(patsubst aarch64,arm64,$(patsubst x86_64,amd64,$(shell uname -m)))

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

# Guard for the `-image` targets (build-image, stamp-image, test-image,
# push-image) and the two per-variant manifest targets (manifest-variant,
# push-manifest-variant), exactly parallel to REQUIRE_ARCH_SH above and needed
# for the same reason: they index the variant tables by $(VARIANT), and make
# expands an unset $(BASE_TAG_) to nothing rather than complaining, so without
# this a bare `make build-image ARCH=amd64` would build under
# `$(LOCAL_IMAGE):-amd64` and fail somewhere much less obvious.
REQUIRE_VARIANT_SH = case "$(VARIANT)" in \
                       tsh|admin) ;; \
                       *) echo "ERROR: this target needs VARIANT=tsh or VARIANT=admin (got '$(VARIANT)'). Run the plain target -- build, test, push -- which does both." >&2; exit 1 ;; \
                     esac

# Extra flags for the build, empty by default. The version is pinned and the
# tarball is verified against a per-architecture digest recorded in the
# Containerfile (not just the same-host .sha256), so a rebuild fetches and
# checks the same bytes every time; this exists for refreshing the base images:
#
#   make build PODMAN_BUILD_FLAGS="--pull"
PODMAN_BUILD_FLAGS ?=

BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REV    := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)

# Shell snippet, expanded inside a recipe. Given $version already set by the
# recipe and VARIANT set by make, it sets $tags to that variant's full tag list.
# manifest-variant and push-manifest-variant both expand it, and nothing else
# does, so the tag scheme stays defined in exactly one place.
#
# Written as one logical line: backslash continuations in a variable assignment
# collapse to spaces, so expanding this inside a recipe cannot introduce a
# newline into the shell command.
#
# The `\#` escapes are required -- an unescaped # starts a comment in a variable
# assignment (though not in a recipe line, where make passes it to the shell).
#
# The final `case` needs no default branch: REQUIRE_VARIANT_SH has already run
# in an earlier recipe line and aborted the target for anything but these two.
#
# `tsh` is an alias of `latest`, and that is the point rather than an oversight.
# It reads as a name only because `tctl` exists beside it -- the same way
# container-ansible's `ubuntu` tag earns its keep by sitting next to `alpine`.
# There is still no `ubuntu` tag here, because no second base OS gives it that
# contrast (D9). The bare major tags `18` and `18-admin` are safe because this
# repo publishes one image family and nothing else can claim them.
TAG_SET_SH = case "$$version" in \
               [0-9]*.[0-9]*.[0-9]*) ;; \
               *) echo "ERROR: $(LOCAL_IMAGE): version '$$version' is not X.Y.Z; refusing to derive the tag set from a malformed version" >&2; exit 1 ;; \
             esac; \
             rest="$${version\#*.}"; \
             major="$${version%%.*}"; \
             minor="$$major.$${rest%%.*}"; \
             case "$(VARIANT)" in \
               tsh)   tags="latest $$major $$minor $$version tsh" ;; \
               admin) tags="tctl admin $$major-admin $$minor-admin $$version-admin" ;; \
             esac

.DEFAULT_GOAL := help
.PHONY: help build build-arch build-image stamp-image check-readme test \
        test-arch test-image manifests manifest-variant push push-arch \
        push-image push-manifests push-manifest-variant check-published \
        check-published-variant clean

help:
	@echo "Targets:"
	@echo "  build   Build both variants for both architectures and assemble the manifest lists"
	@echo "  test    Smoke-test all four images (builds first)"
	@echo "  push    Publish the four arch tags and the ten lists to $(REGISTRY)/$(IMAGE) (builds and tests first)"
	@echo "  clean   Remove every tag and manifest list this repo applies"
	@echo
	@echo "  check-published VERSION=X.Y.Z"
	@echo "          Read the registry back and assert every published list points at"
	@echo "          the arch images published beside it. Needs no local images; runs"
	@echo "          at the end of push, and standalone whenever you want to know."
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

# The ten names the two variants carry are manifest lists over the two arch
# images (D13/D14); this is the fan-out that builds all ten.
#
# VERSION is optional here and required in manifest-variant. CI passes it,
# because its manifest job has no local image to inspect; locally the fallback
# reads it back off the tsh variant's host-architecture member, which is free --
# an inspect of the label stamp-image wrote, not a container start, and of the
# host's member so no emulation is needed. One readback covers both variants for
# the reason spelled out over manifest-variant below.
#
# The readback is wrapped in `if !` rather than left bare because `set -e` would
# otherwise abort the recipe outright when there is no image to inspect, before
# the empty-version check below can say anything useful.
manifests:
	@set -eu; \
	v="$(VERSION)"; \
	if [ -z "$$v" ]; then \
	  if ! { v="$(call READ_VERSION,tsh)"; } 2>/dev/null; then v=""; fi; \
	fi; \
	[ -n "$$v" ] || { \
	  echo "ERROR: no VERSION given, and no $(LOCAL_IMAGE):$(BASE_TAG_tsh)-$(HOST_ARCH) to read one off. Run 'make build' first, or pass VERSION=X.Y.Z." >&2; \
	  exit 1; \
	}; \
	$(MAKE) --no-print-directory manifest-variant VARIANT=tsh   VERSION="$$v"; \
	$(MAKE) --no-print-directory manifest-variant VARIANT=admin VERSION="$$v"

# Both variants ship the same tsh out of the same tarball, so one version covers
# both lists -- the same reason TAG_SET_SH has only ever taken a single $version
# and tag derivation reads tsh rather than tctl.
#
# VERSION is required here rather than read back, unlike in manifests above: the
# CI manifest job has no local image to inspect and receives it as a job output
# from the build job, which read it back off the image exactly as manifests
# does. Either way no hand-typed version reaches the tag derivation, which is
# what D9's readback rule protects.
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

# Three checks beyond the offline smoke test, all against things the smoke
# test itself cannot see (it runs inside the image; README.md and labels are
# both outside it):
#
#   1. README.md names the pinned version somewhere in prose -- the one copy of
#      the pin nothing else cross-checks (spec D4). A plain grep, not a version
#      parse: the point is only to catch the version going unmentioned after a
#      bump, not to validate README prose.
#   2. org.opencontainers.image.licenses is exactly the LicenseRef- SPDX escape
#      hatch this image is supposed to carry (D10).
#   3. org.opencontainers.image.description contains the pinned version, i.e.
#      the label actually interpolates TELEPORT_VERSION rather than a
#      hand-typed string that could drift from it (D3).
#
# 1 is repo-wide and hangs off test-arch as check-readme below; 2 and 3 are
# per-image and live in test-image.
test:
	@$(MAKE) --no-print-directory test-arch ARCH=amd64
	@$(MAKE) --no-print-directory test-arch ARCH=arm64

# A target of its own rather than a line in `test`, because CI never runs
# `test`: both workflow paths enter at test-arch (`make test-arch ARCH=...` on a
# pull request, `make test-arch push-arch ARCH=...` on master) and the manifest
# job runs neither. A check living only in `test` would therefore be enforced by
# nothing in CI, which is the opposite of what D4 claims for this copy of the
# pin. Hanging it off test-arch puts it on every path that tests.
#
# `make test` calls test-arch twice, so a full local run greps README.md twice.
# That is one grep over one file, and cheaper than the stamp file or order-only
# arrangement it would take to run it once.
check-readme:
	@grep -q '$(TELEPORT_VERSION)' README.md || { \
	  echo "FAIL: README.md does not mention $(TELEPORT_VERSION); the version pin" >&2; \
	  echo "      has three copies (Containerfile, Makefile, README.md) and this" >&2; \
	  echo "      is the one nothing else cross-checks -- update README.md in the" >&2; \
	  echo "      same commit as any version bump." >&2; \
	  exit 1; \
	}

# build-arch is a prerequisite rather than something `test` depends on, so that
# a CI runner can say `make test-arch ARCH=arm64` and get the build for free.
# ARCH is a command-line variable in that invocation, so it reaches the
# prerequisite too. check-readme needs no input and is listed first so that a
# serial make reaches it before spending the build on a stale README.
test-arch: check-readme build-arch
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

# Mirror the four architecture images to $(REGISTRY), assemble the ten lists
# from the local members, and mirror those too. Depends on test, so a
# smoke-test failure blocks the publish.
#
# test's prerequisite chain stops at build-arch, which builds the four images
# and nothing else -- manifests is what assembles the lists, and only build
# calls it. So push calls manifests itself rather than relying on test to have
# done it; manifests is idempotent (it clears and recreates each name), so
# this is safe even when a prior `make build` already ran it.
#
# Not atomic, and now in one more sense than before: the arch images go up
# first and the lists that reference them second, so an interruption between
# the two leaves the lists pointing at the previous members while the arch tags
# are already new. Re-running repairs it. This is the failure mode D15 names,
# and it is why the workflow does not cancel in-progress runs on master.
# check-published closes the loop: it reads back what actually landed rather
# than trusting that the pushes above reported success. VERSION is passed
# explicitly because that target reads only the registry and will not fall back
# to a local image.
push: test
	@$(MAKE) --no-print-directory push-arch ARCH=amd64
	@$(MAKE) --no-print-directory push-arch ARCH=arm64
	@$(MAKE) --no-print-directory manifests
	@$(MAKE) --no-print-directory push-manifests
	@set -eu; $(MAKE) --no-print-directory check-published VERSION="$(call READ_VERSION,tsh)"

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
# unchanged blobs. It is not what makes `make push` work either: push mirrors
# the four arch images itself, calling push-arch twice before it reaches
# push-manifests. What --all buys is that `make push-manifests` stands on its
# own -- run against a registry that has never seen the members, it uploads them
# rather than publishing ten lists of references to nothing. Same flag both
# ways, so the two halves stay identical.
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
	if [ -z "$$version" ]; then \
	  if ! { version="$(call READ_VERSION,$(VARIANT))"; } 2>/dev/null; then version=""; fi; \
	fi; \
	[ -n "$$version" ] || { \
	  echo "ERROR: push-manifest-variant found no local image to read the version off; pass VERSION=X.Y.Z" >&2; \
	  exit 1; \
	}; \
	$(TAG_SET_SH); \
	for t in $$tags; do \
	  echo "Pushing $(REGISTRY)/$(IMAGE):$$t (manifest list)"; \
	  $(PODMAN) manifest push --all "$(LOCAL_IMAGE):$$t" "docker://$(REGISTRY)/$(IMAGE):$$t"; \
	done

# ---- verifying what is actually published -----------------------------------
# Asserts that every published list points at exactly the architecture images
# published beside it -- not merely that it has two members of the right
# architectures, which a list left stale by an interrupted run also has.
#
# Both sides are resolved from the registry, and that is the load-bearing
# choice. Comparing a published list against the locally assembled one would
# report a mismatch whenever the local images are a different build, which they
# almost always are: the created and revision labels alone give a local build
# different digests from CI's. Reading both sides remotely makes this meaningful
# at any time, from any checkout, with no local images at all -- including long
# after the run that published them.
#
# `podman manifest add` against a remote reference fetches that image's manifest
# and records its digest; it does not pull layers. A scratch list is therefore
# the cheapest way to ask what digest a tag currently has, and it is how the
# expectation is built.
#
# Scope, stated plainly: this catches a list that was published wrong, a tag
# that never landed, and a list left pointing at a previous run's members. It
# does not, on its own, make an interrupted run fail -- a run that dies before
# push-manifests never reaches this either. What it gives that case is
# detection on the next run, or whenever a human runs it.
CHECK_SCRATCH = $(LOCAL_IMAGE)-check-scratch

# Shell snippet. Given $ref, sets $members to that reference's "arch digest"
# pairs, sorted, one per line -- and fails loudly if the result is not exactly
# the two architectures this repo publishes. Without that shape check a read
# that silently returned nothing would compare empty to empty and pass.
#
# podman's stderr is dropped because its failure here is expected and enormous:
# asked to inspect a plain image as a list it prints the entire manifest blob
# into the error string. The shape check below reports the same fact in one
# line. The cost is that a network or auth failure also arrives as an empty
# read, so the message names that possibility rather than asserting which
# happened.
MANIFEST_MEMBERS_SH = members="$$($(PODMAN) manifest inspect "$$ref" 2>/dev/null \
                        | $(JQ) -r '.manifests[] | "\(.platform.architecture) \(.digest)"' \
                        | sort)"; \
                      got="$$(echo "$$members" | $(AWK) 'NF{print $$1}' | paste -sd, -)"; \
                      [ "$$got" = "amd64,arm64" ] || { \
                        echo "FAIL: $$ref did not read back as a manifest list of exactly amd64+arm64 (got '$$got')." >&2; \
                        echo "      Either it is not a list -- a plain image under that name -- or the registry could not be read." >&2; \
                        exit 1; \
                      }

check-published:
	@$(MAKE) --no-print-directory check-published-variant VARIANT=tsh   VERSION="$(VERSION)"
	@$(MAKE) --no-print-directory check-published-variant VARIANT=admin VERSION="$(VERSION)"

# VERSION is required, not read back: this target is about the registry and must
# not depend on a local image existing at all.
check-published-variant:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; \
	version="$(VERSION)"; \
	[ -n "$$version" ] || { \
	  echo "ERROR: check-published-variant needs VERSION=X.Y.Z; it reads only the registry and has no image to read one off." >&2; \
	  exit 1; \
	}; \
	$(TAG_SET_SH); \
	base="$(BASE_TAG_$(VARIANT))"; \
	$(PODMAN) manifest exists "$(CHECK_SCRATCH)" 2>/dev/null && $(PODMAN) manifest rm "$(CHECK_SCRATCH)" >/dev/null || true; \
	$(PODMAN) manifest create "$(CHECK_SCRATCH)" >/dev/null; \
	$(PODMAN) manifest add "$(CHECK_SCRATCH)" "$(REGISTRY)/$(IMAGE):$$base-amd64" >/dev/null; \
	$(PODMAN) manifest add "$(CHECK_SCRATCH)" "$(REGISTRY)/$(IMAGE):$$base-arm64" >/dev/null; \
	ref="$(CHECK_SCRATCH)"; $(MANIFEST_MEMBERS_SH); \
	expected="$$members"; \
	$(PODMAN) manifest rm "$(CHECK_SCRATCH)" >/dev/null; \
	for t in $$tags; do \
	  ref="$(REGISTRY)/$(IMAGE):$$t"; $(MANIFEST_MEMBERS_SH); \
	  [ "$$members" = "$$expected" ] || { \
	    echo "FAIL: $(REGISTRY)/$(IMAGE):$$t does not point at the published $$base-amd64/$$base-arm64 images" >&2; \
	    echo "  published list:" >&2; echo "$$members"   | sed 's/^/    /' >&2; \
	    echo "  arch tags:"      >&2; echo "$$expected"  | sed 's/^/    /' >&2; \
	    exit 1; \
	  }; \
	done; \
	echo "Verified $(VARIANT): $$tags all point at $$base-amd64 + $$base-arm64"

# Removes the ten lists and four arch images this repo applies, across both
# variants. `podman push SOURCE DESTINATION` never creates a registry-qualified
# local tag, so this localhost-anchored match still covers the complete set. It
# does NOT reclaim the orphaned <none> layer the label build in `stamp-image`
# leaves behind -- podman rmi on a tag does not cascade to the image it was
# derived from. Run `podman image prune` for those; this target deliberately
# does not, since a blanket prune would delete images this repo never built.
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
