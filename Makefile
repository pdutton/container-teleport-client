IMAGE    ?= teleport-client

# The Teleport version this image pins. Written here AND as ARG
# TELEPORT_VERSION in the Containerfile, deliberately independent: this copy is
# only ever handed to the smoke test as EXPECT_VERSION, and is never passed as a
# --build-arg. If it were, the two could not disagree and the smoke test's
# version assertion would be vacuous.
#
# So editing one alone does NOT break `podman build` -- the image builds fine --
# it breaks `make test`. That is the safety net working, not a bug. Bumping the
# pin means editing both, plus the version named in README.md, which nothing
# cross-checks.
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

# Extra flags for the build, empty by default. The version is pinned, so unlike
# the sibling repos a plain rebuild is already reproducible; this exists for
# refreshing the base images:
#
#   make build PODMAN_BUILD_FLAGS="--pull"
PODMAN_BUILD_FLAGS ?=

BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REV    := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)

# Shell snippet, expanded inside a recipe. Given $version already set by the
# recipe, it sets $tags to the full tag list. Both `tag` and `push` expand it,
# so the tag scheme is defined in exactly one place.
#
# Written as one logical line: backslash continuations in a variable assignment
# collapse to spaces, so expanding this inside a recipe cannot introduce a
# newline into the shell command.
#
# The `\#` escapes are required -- an unescaped # starts a comment in a variable
# assignment (though not in a recipe line, where make passes it to the shell).
#
# There is deliberately no `ubuntu` tag: with a single image it would be a
# permanent alias of `latest`. The bare major tag `18` IS safe here, unlike in
# container-terraform, because there is one image and nothing else can claim it.
TAG_SET_SH = case "$$version" in \
               [0-9]*.[0-9]*.[0-9]*) ;; \
               *) echo "ERROR: $(LOCAL_IMAGE): version '$$version' is not X.Y.Z; refusing to derive the tag set from a malformed version" >&2; exit 1 ;; \
             esac; \
             rest="$${version\#*.}"; \
             tags="latest $${version%%.*} $${version%%.*}.$${rest%%.*} $$version"

.DEFAULT_GOAL := help
.PHONY: help build tag test push clean

help:
	@echo "Targets:"
	@echo "  build   Build $(LOCAL_IMAGE) and apply the full tag set"
	@echo "  test    Smoke-test the image (builds first)"
	@echo "  push    Publish every tag to $(REGISTRY)/$(IMAGE) (builds and tests first)"
	@echo "  clean   Remove every tag this repo applies"
	@echo
	@echo "Pinned Teleport version: $(TELEPORT_VERSION)"
	@echo "Bumping it means editing the Makefile, the Containerfile and README.md."

build:
	$(PODMAN) build -t $(LOCAL_IMAGE):latest \
	  --label org.opencontainers.image.created=$(BUILD_DATE) \
	  --label org.opencontainers.image.revision=$(GIT_REV) \
	  $(PODMAN_BUILD_FLAGS) \
	  .
	@$(MAKE) --no-print-directory tag

# Read the version out of the freshly built image, stamp it on as a label, and
# apply the full tag set, so no tag can drift from what is actually installed.
# `tsh version` prints "Teleport v18.10.4 git:... go1.25.11" on its first line;
# field 2 is the version and the leading v is stripped. The X.Y.Z shape check
# lives in TAG_SET_SH and runs before any tag is applied.
tag:
	@set -eu; \
	version=$$($(PODMAN) run --rm $(LOCAL_IMAGE):latest tsh version | $(AWK) 'NR==1{print $$2}'); \
	version=$${version#v}; \
	$(TAG_SET_SH); \
	printf 'FROM %s:latest\nLABEL org.opencontainers.image.version="%s"\n' "$(LOCAL_IMAGE)" "$$version" \
	  | $(PODMAN) build -f - -t "$(LOCAL_IMAGE):latest" .; \
	for t in $$tags; do $(PODMAN) tag "$(LOCAL_IMAGE):latest" "$(LOCAL_IMAGE):$$t"; done; \
	echo "Tagged $(LOCAL_IMAGE): $$tags"

test: build
	$(PODMAN) run --rm -v ./test:/apps:ro,z \
	  -e EXPECT_VERSION=$(TELEPORT_VERSION) \
	  $(LOCAL_IMAGE):latest sh /apps/smoke.sh

# Mirror every tag to $(REGISTRY). Depends on test, so a smoke-test failure
# blocks the publish and a broken image cannot reach the registry this way.
#
# The version is read back off the label `tag` applied rather than by running the
# container again -- an inspect, not a container start.
#
# Not atomic: a failure partway through the loop leaves the earlier tags already
# published and the rest stale. The failure is loud, which is the requirement,
# but it is not a rollback.
push: test
	@set -eu; \
	version=$$($(PODMAN) image inspect \
	  --format '{{index .Labels "org.opencontainers.image.version"}}' $(LOCAL_IMAGE):latest); \
	$(TAG_SET_SH); \
	for t in $$tags; do \
	  echo "Pushing $(REGISTRY)/$(IMAGE):$$t"; \
	  $(PODMAN) push "$(LOCAL_IMAGE):$$t" "$(REGISTRY)/$(IMAGE):$$t"; \
	done

# Removes the four tags this repo applies. `podman push SOURCE DESTINATION`
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
