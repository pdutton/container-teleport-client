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
AWK      ?= /usr/bin/awk
PODMAN   ?= /usr/bin/podman

# Registry the push target publishes to. Override to retarget:
# `make push REGISTRY=ghcr.io/pdutton`
#
# The account here must match the DOCKERHUB_USERNAME repository secret CI logs
# in with. If they disagree nothing fails early: `podman login` succeeds against
# the wrong account and the push 401s on its first tag.
REGISTRY ?= docker.io/pdutton

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
# as $(<SETTING>_$(VARIANT)). The plain targets (build, tag, test, push) each
# re-invoke make once per variant; the `-variant` targets they call are the ones
# that do the work and require VARIANT to be set.
#
# Adding a third variant means adding a row to each table here, a branch to
# TAG_SET_SH, a name to REQUIRE_VARIANT_SH, and one line to each plain target --
# but no new recipe. The fan-out is written out rather than looped over a
# VARIANTS list on purpose: two literal lines survive `make -n` legibly and
# cannot swallow a non-zero exit the way a `for` loop in a recipe can.
INCLUDE_TCTL_tsh   := false
INCLUDE_TCTL_admin := true

# The tag each variant's build writes first; every later step reads the image
# back from it. Both are members of their own variant's tag set, so the
# base-to-base retag in `tag-variant` is a harmless no-op.
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

# Guard for the `-variant` targets. They index the tables above by $(VARIANT),
# and make expands an unset $(BASE_TAG_) to nothing rather than complaining, so
# without this a bare `make tag` would run against `$(LOCAL_IMAGE):` and fail
# somewhere much less obvious.
REQUIRE_VARIANT_SH = case "$(VARIANT)" in \
                       tsh|admin) ;; \
                       *) echo "ERROR: this target needs VARIANT=tsh or VARIANT=admin (got '$(VARIANT)'). Run the plain target -- build, tag, test, push -- which does both." >&2; exit 1 ;; \
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
# Both `tag-variant` and `push-variant` expand it, so the tag scheme is defined
# in exactly one place.
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
.PHONY: help build build-variant tag tag-variant test test-variant push push-variant clean

help:
	@echo "Targets:"
	@echo "  build   Build both variants of $(LOCAL_IMAGE) and apply the full tag set"
	@echo "  test    Smoke-test both variants (builds first)"
	@echo "  push    Publish every tag to $(REGISTRY)/$(IMAGE) (builds and tests first)"
	@echo "  clean   Remove every tag this repo applies"
	@echo
	@echo "Variants (one Containerfile, gated on the INCLUDE_TCTL build arg):"
	@echo "  tsh     tsh alone     -> latest, 18, 18.10, $(TELEPORT_VERSION), tsh"
	@echo "  admin   tsh and tctl  -> tctl, admin, 18-admin, 18.10-admin, $(TELEPORT_VERSION)-admin"
	@echo
	@echo "Each target does both variants. Add VARIANT=tsh or VARIANT=admin to the"
	@echo "matching -variant target (build-variant, tag-variant, ...) to do just one."
	@echo
	@echo "Pinned Teleport version: $(TELEPORT_VERSION)"
	@echo "Bumping it means editing the Makefile, the two per-arch digests and"
	@echo "TELEPORT_VERSION in the Containerfile, and README.md."

build:
	@$(MAKE) --no-print-directory build-variant VARIANT=tsh
	@$(MAKE) --no-print-directory build-variant VARIANT=admin

build-variant:
	@set -eu; $(REQUIRE_VARIANT_SH)
	$(PODMAN) build -t $(LOCAL_IMAGE):$(BASE_TAG_$(VARIANT)) \
	  --build-arg INCLUDE_TCTL=$(INCLUDE_TCTL_$(VARIANT)) \
	  $(DESC_LABEL_$(VARIANT)) \
	  --label org.opencontainers.image.created=$(BUILD_DATE) \
	  --label org.opencontainers.image.revision=$(GIT_REV) \
	  $(PODMAN_BUILD_FLAGS) \
	  .
	@$(MAKE) --no-print-directory tag-variant VARIANT=$(VARIANT)

tag:
	@$(MAKE) --no-print-directory tag-variant VARIANT=tsh
	@$(MAKE) --no-print-directory tag-variant VARIANT=admin

# Read the version out of the freshly built image, stamp it on as a label, and
# apply that variant's full tag set, so no tag can drift from what is actually
# installed. `tsh version` prints "Teleport v18.10.4 git:... go1.25.11" on its
# first line; field 2 is the version and the leading v is stripped. tsh is read
# rather than tctl because it is the one binary both variants have. The X.Y.Z
# shape check lives in TAG_SET_SH and runs before any tag is applied.
tag-variant:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; \
	base="$(BASE_TAG_$(VARIANT))"; \
	version=$$($(PODMAN) run --rm $(LOCAL_IMAGE):$$base tsh version | $(AWK) 'NR==1{print $$2}'); \
	version=$${version#v}; \
	$(TAG_SET_SH); \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(LOCAL_IMAGE)" "$$base" "$$version" \
	  | $(PODMAN) build -f - -t "$(LOCAL_IMAGE):$$base" .; \
	for t in $$tags; do $(PODMAN) tag "$(LOCAL_IMAGE):$$base" "$(LOCAL_IMAGE):$$t"; done; \
	echo "Tagged $(LOCAL_IMAGE) ($(VARIANT)): $$tags"

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
test: build
	@grep -q '$(TELEPORT_VERSION)' README.md || { \
	  echo "FAIL: README.md does not mention $(TELEPORT_VERSION); the version pin" >&2; \
	  echo "      has three copies (Containerfile, Makefile, README.md) and this" >&2; \
	  echo "      is the one nothing else cross-checks -- update README.md in the" >&2; \
	  echo "      same commit as any version bump." >&2; \
	  exit 1; \
	}
	@$(MAKE) --no-print-directory test-variant VARIANT=tsh
	@$(MAKE) --no-print-directory test-variant VARIANT=admin

test-variant:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; \
	expected="LicenseRef-Teleport-Community-Edition"; \
	actual=$$($(PODMAN) image inspect --format '{{index .Config.Labels "org.opencontainers.image.licenses"}}' $(LOCAL_IMAGE):$(BASE_TAG_$(VARIANT))); \
	[ "$$actual" = "$$expected" ] || { \
	  echo "FAIL: $(VARIANT): org.opencontainers.image.licenses label is '$$actual', expected '$$expected'" >&2; \
	  exit 1; \
	}
	@set -eu; \
	expected="$(DESC_$(VARIANT))"; \
	actual=$$($(PODMAN) image inspect --format '{{index .Config.Labels "org.opencontainers.image.description"}}' $(LOCAL_IMAGE):$(BASE_TAG_$(VARIANT))); \
	[ "$$actual" = "$$expected" ] || { \
	  echo "FAIL: $(VARIANT): org.opencontainers.image.description label is '$$actual', expected '$$expected'" >&2; \
	  echo "      (expected the pinned version $(TELEPORT_VERSION) interpolated into it)" >&2; \
	  exit 1; \
	}
	$(PODMAN) run --rm -v ./test:/apps:ro,z \
	  -e EXPECT_VERSION=$(TELEPORT_VERSION) \
	  -e EXPECT_TCTL=$(EXPECT_TCTL_$(VARIANT)) \
	  $(LOCAL_IMAGE):$(BASE_TAG_$(VARIANT)) sh /apps/smoke.sh

# Mirror every tag to $(REGISTRY). Depends on test, so a smoke-test failure
# blocks the publish and a broken image cannot reach the registry this way.
#
# The version is read back off the label `tag-variant` applied rather than by
# running the container again -- an inspect, not a container start.
#
# Not atomic, in two senses now: a failure partway through the loop leaves the
# earlier tags of that variant published and the rest stale, and a failure in
# the admin pass leaves the tsh variant already published. The failure is loud,
# which is the requirement, but it is not a rollback.
push: test
	@$(MAKE) --no-print-directory push-variant VARIANT=tsh
	@$(MAKE) --no-print-directory push-variant VARIANT=admin

push-variant:
	@set -eu; $(REQUIRE_VARIANT_SH)
	@set -eu; \
	version=$$($(PODMAN) image inspect \
	  --format '{{index .Labels "org.opencontainers.image.version"}}' $(LOCAL_IMAGE):$(BASE_TAG_$(VARIANT))); \
	$(TAG_SET_SH); \
	for t in $$tags; do \
	  echo "Pushing $(REGISTRY)/$(IMAGE):$$t"; \
	  $(PODMAN) push "$(LOCAL_IMAGE):$$t" "$(REGISTRY)/$(IMAGE):$$t"; \
	done

# Removes the ten tags this repo applies, across both variants. `podman push SOURCE DESTINATION`
# never creates a registry-qualified local tag, so this localhost-anchored match
# still covers the complete set. It does NOT reclaim the orphaned <none> layer
# the `tag` target's label build leaves behind -- podman rmi on a tag does not
# cascade to the image it was derived from. Run `podman image prune` for those;
# this target deliberately does not, since a blanket prune would delete images
# this repo never built.
clean:
	@ids=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then $(PODMAN) rmi -f $$ids; else echo "nothing to clean"; fi
