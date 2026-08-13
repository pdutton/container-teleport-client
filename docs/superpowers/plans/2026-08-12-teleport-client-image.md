# Teleport Client Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish a container image carrying Teleport Community
Edition's `tsh` client, so `tsh login`, `tsh ssh`, and a `tsh ssh` port forward
carrying VNC all work from a host with no Teleport client installed.

**Architecture:** A two-stage `podman` build — a discarded `alpine:3.23` stage
downloads and checksum-verifies the Teleport tarball from `cdn.teleport.dev` and
extracts exactly two files, and an `ubuntu:26.04` stage adds `ca-certificates`
and receives them. A `Makefile` builds, tags (by reading the version back out of
the built image), smoke-tests and publishes; GitHub Actions runs the same targets
on pull requests and publishes from `master`.

**Tech Stack:** podman 5.8.1, GNU Make, POSIX `sh` for the smoke test, GitHub
Actions, Docker Hub.

**Spec:** `docs/superpowers/specs/2026-08-12-teleport-client-image-design.md`
(referenced below as M1–M5 for measured facts and D1–D11 for decisions).

## Global Constraints

- **Pinned Teleport version: `18.10.4`.** It appears in exactly three places —
  `ARG TELEPORT_VERSION` in `Containerfile`, `TELEPORT_VERSION` in `Makefile`,
  and prose in `README.md`. The Makefile copy is **never** passed as a
  `--build-arg`; the two must stay independent or the smoke test's version
  assertion becomes vacuous (D4).
- **Base images:** `docker.io/library/alpine:3.23` (downloader stage, discarded),
  `docker.io/library/ubuntu:26.04` (final image). Fully qualified, always.
- **Local image reference is `localhost/teleport-client`**, never a bare short
  name — a bare name can resolve to a non-localhost repo, and the push source
  must not depend on that tie-break (D11).
- **Published as `docker.io/pdutton/teleport-client`.**
- **Tag set: `latest`, `18`, `18.10`, `18.10.4`.** No `ubuntu` tag (D9).
- **Image contents: `/usr/local/bin/tsh`,
  `/usr/share/doc/teleport/LICENSE-community`, and the `ca-certificates`
  package. Nothing else.** `teleport`, `tctl`, `tbot`, `curl` and `wget` must all
  be absent (D5).
- **Image licence label:
  `org.opencontainers.image.licenses="LicenseRef-Teleport-Community-Edition"`**
  — not AGPL, not Apache-2.0 (D10, M5).
- **This repo's own code is AGPL-3.0-only.**
- **`WORKDIR /apps`, `CMD ["tsh", "--help"]`, image runs as root with
  `HOME=/root`.**
- All work happens on the `feature/initial-image` worktree at
  `~/projects/container-teleport/feature/initial-image`. Never commit in
  `primary/`.

---

### Task 1: Repository scaffolding and licence

**Files:**
- Create: `LICENSE`
- Create: `.gitignore`
- Create: `.dockerignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `.dockerignore` keeps the build context small for Task 2's
  `podman build .`; `LICENSE` is referenced by `README.md` in Task 6.

- [ ] **Step 1: Fetch the AGPL-3.0 text**

The repo's own code is AGPL-3.0-only (D10). Fetch the canonical text rather than
transcribing it:

```bash
cd ~/projects/container-teleport/feature/initial-image
curl -fsSL https://www.gnu.org/licenses/agpl-3.0.txt -o LICENSE
```

- [ ] **Step 2: Verify it is the right licence and complete**

```bash
head -3 LICENSE
grep -c . LICENSE
grep -n "Remote Network Interaction" LICENSE
```

Expected: the header names "GNU AFFERO GENERAL PUBLIC LICENSE" and "Version 3,
19 November 2007"; the file is several hundred non-empty lines; section 13
"Remote Network Interaction; Use with the GNU General Public License" is present
(that section is what distinguishes AGPL from GPL — if it is missing, the wrong
file was downloaded).

- [ ] **Step 3: Write `.gitignore`**

Copied from the sibling repos so vim leftovers and subagent workspaces stay out:

```
# Vim temporary files
# Swap files, including the dot-prefixed form vim uses beside the edited file
# (e.g. .Makefile.swp)
[._]*.s[a-v][a-z]
[._]*.sw[a-p]
[._]s[a-v][a-z]
[._]sw[a-p]
*.s[a-v][a-z]
*.sw[a-p]

# Backup files and persistent undo
*~
[._]*.un~
*.un~

# Session and netrw history
Session.vim
Sessionx.vim
.netrwhist

# Superpowers subagent workspace (process artifacts, not project content)
.superpowers/
```

- [ ] **Step 4: Write `.dockerignore`**

Nothing in this repo is `COPY`d into the image — both files come from the
downloader stage — so the build context can be empty of everything:

```
.git/
.github/
docs/
test/
Makefile
README.md
DOCKERHUB-OVERVIEW.md
CLAUDE.md
LICENSE
.superpowers/
```

- [ ] **Step 5: Commit**

```bash
git add LICENSE .gitignore .dockerignore
git commit -m "chore: add AGPL-3.0 licence and ignore files"
```

---

### Task 2: The image and its smoke test

**Files:**
- Create: `test/smoke.sh`
- Create: `Containerfile`

**Interfaces:**
- Consumes: `.dockerignore` from Task 1.
- Produces: an image whose contract later tasks depend on —
  `/usr/local/bin/tsh`, `/usr/share/doc/teleport/LICENSE-community`,
  `WORKDIR /apps`, `CMD ["tsh", "--help"]`, and a build arg named
  `TELEPORT_VERSION`. `test/smoke.sh` reads `EXPECT_VERSION` from the
  environment and is invoked as `sh /apps/smoke.sh` with `test/` mounted at
  `/apps`; Task 3's `make test` calls it exactly that way.

The test is written first and run against the bare Ubuntu base to see it fail
for the right reason, which is the only honest red state available for an image
build.

- [ ] **Step 1: Write the failing test**

Create `test/smoke.sh`:

```sh
#!/bin/sh
set -eu

: "${EXPECT_VERSION:?EXPECT_VERSION must be set}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# (a) The binary must be at /usr/local/bin/tsh specifically. That path is the
# contract for anyone building FROM this image or COPY --from-ing out of it, so
# assert the path rather than inferring it from tsh being somewhere on PATH.
{ [ -f /usr/local/bin/tsh ] && [ -x /usr/local/bin/tsh ]; } \
  || fail "/usr/local/bin/tsh is missing or not executable"

# (b) The version must be exactly the pin. ARG TELEPORT_VERSION in the
# Containerfile and TELEPORT_VERSION in the Makefile are deliberately
# independent (D4); this is where a drift between them surfaces.
# `tsh version` line 1: "Teleport v18.10.4 git:v18.10.4-0-g451ae8d9 go1.25.11"
version="$(tsh version | awk 'NR==1{print $2}')"
version="${version#v}"
echo "tsh version: $version"
[ "$version" = "$EXPECT_VERSION" ] \
  || fail "tsh is $version, expected $EXPECT_VERSION"

# (c) The exclusions are contract, not accident (D5). teleport/tctl/tbot were
# never copied in; curl and wget are absent because the download happens in a
# stage that is discarded (D2), and the Ubuntu base ships neither (M1).
for b in teleport tctl tbot curl wget; do
  ! command -v "$b" >/dev/null 2>&1 || fail "$b is present; it must not be"
done

# (d) tsh carries no trust store of its own and the Ubuntu base ships none, so
# without this package tsh cannot validate the proxy certificate (M1).
[ -s /etc/ssl/certs/ca-certificates.crt ] \
  || fail "/etc/ssl/certs/ca-certificates.crt is missing or empty"

# (e) A licence obligation rather than a feature: section 4(a) of the Teleport
# Community Edition License requires recipients to be given a copy, and this
# image redistributes the binary (M5). A refactor of the COPY lines could drop
# it with nothing a user does ever revealing the loss.
[ -s /usr/share/doc/teleport/LICENSE-community ] \
  || fail "/usr/share/doc/teleport/LICENSE-community is missing or empty"

# (f) /root/.tsh is the mount point README tells people to bind their identity
# to (D7), so assert the image actually presents it rather than assuming.
[ "${HOME:-}" = /root ] || fail "HOME is '${HOME:-}', expected /root"
mkdir -p "$HOME/.tsh" || fail "$HOME/.tsh could not be created"
: > "$HOME/.tsh/.smoke-probe" || fail "$HOME/.tsh is not writable"
rm -f "$HOME/.tsh/.smoke-probe"

echo "PASS: teleport-client $version smoke test ok"
```

- [ ] **Step 2: Run the test against the bare base to verify it fails**

```bash
cd ~/projects/container-teleport/feature/initial-image
podman run --rm -v ./test:/apps:ro,z -e EXPECT_VERSION=18.10.4 \
  docker.io/library/ubuntu:26.04 sh /apps/smoke.sh; echo "exit=$?"
```

Expected: `FAIL: /usr/local/bin/tsh is missing or not executable` and `exit=1`.
Any other message means the test is failing for the wrong reason — fix the test
before going on.

- [ ] **Step 3: Write the `Containerfile`**

```dockerfile
# Declared once, before any FROM, so it is global and both stages take it into
# scope with a bare `ARG TELEPORT_VERSION`: the downloader builds the URL from
# it and the final stage's description label interpolates it, so the published
# label cannot advertise a version the image is not on.
ARG TELEPORT_VERSION=18.10.4

# ---- stage 1: download and verify -------------------------------------------
# Thrown away entirely. curl never reaches the shipping image -- the Ubuntu base
# has neither curl nor wget (M1), and this stage is the reason it needs neither.
FROM docker.io/library/alpine:3.23 AS downloader

ARG TELEPORT_VERSION

RUN apk add --no-cache curl

RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  arch=amd64 ;; \
      aarch64) arch=arm64 ;; \
      *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;; \
    esac; \
# `teleport-`, not `teleport-ent-`: that prefix is the entire difference between
# the Community and Enterprise builds served from this host.
    tarball="teleport-v${TELEPORT_VERSION}-linux-${arch}-bin.tar.gz"; \
    curl -fsSLO "https://cdn.teleport.dev/${tarball}"; \
    curl -fsSLO "https://cdn.teleport.dev/${tarball}.sha256"; \
# Integrity, not authenticity: this checksum is served by the same host as the
# tarball, so it proves the download was not corrupted or truncated -- not that
# Teleport authored the bytes. No detached signature is published for these
# archives; TLS to cdn.teleport.dev is what carries the trust (D6).
    sha256sum -c "${tarball}.sha256"; \
# Two members out of a 217 MB archive: the client, and the licence that section
# 4(a) requires to travel with any redistribution of it (M5). Extract-then-move
# rather than --strip-components, which busybox tar does not reliably support.
    tar -xzf "${tarball}" -C /tmp teleport/tsh teleport/LICENSE-community; \
    mkdir /out; \
    mv /tmp/teleport/tsh /tmp/teleport/LICENSE-community /out/

# ---- stage 2: the image -----------------------------------------------------
FROM docker.io/library/ubuntu:26.04

ARG TELEPORT_VERSION

LABEL org.opencontainers.image.title="teleport-client" \
      org.opencontainers.image.description="Teleport ${TELEPORT_VERSION} Community Edition client (tsh) on Ubuntu 26.04" \
      org.opencontainers.image.licenses="LicenseRef-Teleport-Community-Edition" \
      org.opencontainers.image.source="https://github.com/pdutton/container-teleport-client" \
      org.opencontainers.image.url="https://github.com/pdutton/container-teleport-client" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:26.04"

# Load-bearing, not hygiene: tsh validates the proxy's certificate and carries no
# trust store of its own, and the Ubuntu base ships none either (M1).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=downloader /out/tsh /usr/local/bin/tsh
COPY --from=downloader /out/LICENSE-community /usr/share/doc/teleport/LICENSE-community

WORKDIR /apps
CMD ["tsh", "--help"]
```

- [ ] **Step 4: Build the image**

```bash
podman build -t localhost/teleport-client:latest .
```

Expected: the build succeeds. The download is ~217 MB, so the first build takes
a minute or two. `sha256sum -c` must print
`teleport-v18.10.4-linux-amd64-bin.tar.gz: OK`.

- [ ] **Step 5: Run the test to verify it passes**

```bash
podman run --rm -v ./test:/apps:ro,z -e EXPECT_VERSION=18.10.4 \
  localhost/teleport-client:latest sh /apps/smoke.sh
```

Expected: `tsh version: 18.10.4` then `PASS: teleport-client 18.10.4 smoke test ok`.

- [ ] **Step 6: Negative control — prove the version assertion can fail**

An assertion that has never failed is not known to work:

```bash
podman run --rm -v ./test:/apps:ro,z -e EXPECT_VERSION=18.10.99 \
  localhost/teleport-client:latest sh /apps/smoke.sh; echo "exit=$?"
```

Expected: `FAIL: tsh is 18.10.4, expected 18.10.99` and `exit=1`.

- [ ] **Step 7: Sanity-check the image by hand**

```bash
podman run --rm localhost/teleport-client:latest tsh version
podman image inspect --format '{{.Labels}}' localhost/teleport-client:latest
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep teleport-client
```

Expected: version `v18.10.4`; the labels include
`org.opencontainers.image.licenses:LicenseRef-Teleport-Community-Edition` and a
description naming 18.10.4; size roughly 250 MB. A size near 600 MB means more
than `tsh` was copied out of the tarball.

- [ ] **Step 8: Commit**

```bash
git add Containerfile test/smoke.sh
git commit -m "feat: build the Teleport client image and smoke-test it"
```

---

### Task 3: Makefile

**Files:**
- Create: `Makefile`

**Interfaces:**
- Consumes: `Containerfile` and `test/smoke.sh` from Task 2.
- Produces: targets `help` (default), `build`, `tag`, `test`, `push`, `clean`,
  and the variables `IMAGE`, `TELEPORT_VERSION`, `REGISTRY`, `PODMAN`, `AWK`,
  `PODMAN_BUILD_FLAGS`. Task 4's CI calls `make test` and `make push`; Task 6's
  README documents these names.

- [ ] **Step 1: Write the `Makefile`**

Adapted from `~/projects/container-terraform/primary/Makefile` with the variant
machinery removed (D1) — no `VARIANTS` list, no `%`-pattern rules, and no
variant-shape guard in `TAG_SET_SH`, which existed only to stop one variant
claiming another's tags.

```makefile
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
```

- [ ] **Step 2: Verify the default goal and the help text**

```bash
cd ~/projects/container-teleport/feature/initial-image
make
```

Expected: the target list, `Pinned Teleport version: 18.10.4`, and no build.

- [ ] **Step 3: Run the full build-and-test cycle**

```bash
make test
```

Expected: a build, then `Tagged localhost/teleport-client: latest 18 18.10
18.10.4`, then the smoke test's `PASS` line.

- [ ] **Step 4: Verify the tag set and the stamped version label**

```bash
podman images --format '{{.Repository}}:{{.Tag}}' | grep teleport-client | sort
podman image inspect --format \
  '{{index .Labels "org.opencontainers.image.version"}}' \
  localhost/teleport-client:latest
```

Expected: exactly the four tags `latest`, `18`, `18.10`, `18.10.4` — no
`ubuntu`, no `<none>` among them — and the label reads `18.10.4`.

- [ ] **Step 5: Verify the cross-check between Makefile and Containerfile fires**

This is the safety net D4 exists for, so prove it works:

```bash
sed -i 's/^TELEPORT_VERSION := 18.10.4/TELEPORT_VERSION := 18.10.3/' Makefile
make test; echo "exit=$?"
sed -i 's/^TELEPORT_VERSION := 18.10.3/TELEPORT_VERSION := 18.10.4/' Makefile
grep -n '^TELEPORT_VERSION' Makefile
```

Expected: `make test` fails with `FAIL: tsh is 18.10.4, expected 18.10.3` and a
non-zero exit; then the `grep` shows `TELEPORT_VERSION := 18.10.4` again. Check
that line by eye before committing — `Makefile` is still untracked at this point,
so `git diff` would report nothing whether or not the revert worked.

- [ ] **Step 6: Verify `clean` is scoped to this repo's tags**

```bash
podman images --format '{{.Repository}}:{{.Tag}}' | wc -l
make clean
podman images --format '{{.Repository}}:{{.Tag}}' | grep -c teleport-client || echo "0 teleport-client tags"
podman images --format '{{.Repository}}:{{.Tag}}' | grep -c 'ansible\|terraform'
```

Expected: `make clean` removes the four `teleport-client` tags and nothing else —
the ansible and terraform images from the sibling repos must still be present.

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "feat: add Makefile with build, tag, test, push and clean targets"
```

---

### Task 4: CI workflow

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `make test` and `make push` from Task 3.
- Produces: nothing other tasks consume. Requires two repository secrets,
  `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`, and reads
  `DOCKERHUB-OVERVIEW.md`, which Task 6 creates.

- [ ] **Step 1: Write the workflow**

Adapted from `~/projects/container-terraform/primary/.github/workflows/build.yml`
with the matrix removed (D1) — one image means one job, so `fail-fast` and the
"one channel must not stop the other" reasoning no longer apply.

```yaml
name: build

on:
  pull_request:
  push:
    branches: [master]
  workflow_dispatch:

# Nothing here writes to the repository.
permissions:
  contents: read

# Cancel superseded pull-request runs, but let a master push finish -- a
# cancellation mid-push would leave the tag set half-updated in the registry.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  build:
    name: build
    runs-on: ubuntu-latest

    steps:
      # v7 runs on Node.js 24. v4 targets Node.js 20, which is deprecated, and
      # the runner forces it onto 24 anyway while warning on every job.
      - uses: actions/checkout@v7

      # Default checkout depth is fine: the Makefile's `git rev-parse HEAD`
      # works at depth 1.

      - name: Ensure podman
        run: |
          if ! command -v podman >/dev/null; then
            sudo apt-get update
            sudo apt-get install -y podman
          fi
          # The Makefile defaults to absolute tool paths; fail loudly here
          # rather than with a confusing "no such file" mid-build.
          test -x /usr/bin/podman
          test -x /usr/bin/awk
          podman --version

      # Publishing happens only from master. A dispatch against another branch
      # still builds and smoke-tests, so a branch can be put through CI, but it
      # must never overwrite the shared mutable tags (latest, 18, 18.10) with
      # unreviewed code. This condition is the exact negation of the publish
      # condition below -- if it were merely the pull_request check, a dispatch
      # from a feature branch would match no step at all and the job would
      # silently pass having done nothing.
      - name: Build and smoke-test
        if: github.event_name == 'pull_request' || github.ref != 'refs/heads/master'
        run: make test

      - name: Log in to Docker Hub
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        env:
          DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
        run: printf '%s' "$DOCKERHUB_TOKEN" | podman login docker.io -u "$DOCKERHUB_USERNAME" --password-stdin

      # One invocation, not two: push depends on test which depends on build, so
      # this builds, smoke-tests and publishes. Running `make test` in a separate
      # step first would repeat the whole chain -- these targets are .PHONY and
      # match no real file, so make re-runs them on every invocation.
      - name: Build, smoke-test, and push
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        run: make push

  # Docker Hub reads nothing from this repo on its own, so the overview page
  # would drift from DOCKERHUB-OVERVIEW.md the moment either is edited alone.
  # Same master-only guard as the publish steps: the page is shared by every
  # consumer and a branch build must not rewrite it.
  description:
    name: dockerhub-description
    runs-on: ubuntu-latest
    needs: build
    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'

    steps:
      - uses: actions/checkout@v7

      # The short description is set here too, so the whole Hub page is
      # declarative -- leaving it unset would silently preserve whatever was
      # last typed into the web UI.
      # Pinned by SHA, not by tag: this is the only third-party action here and
      # it is handed a Docker Hub token with write/delete scope. A tag is a
      # mutable pointer in someone else's repository -- repointing v5 would run
      # new code against that secret with no change on this side.
      # actions/checkout stays on a major tag; it is inside GitHub's own trust
      # boundary.
      - uses: peter-evans/dockerhub-description@1b9a80c056b620d92cedb9d9b5a223409c68ddfa # v5.0.0
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
          repository: pdutton/teleport-client
          readme-filepath: ./DOCKERHUB-OVERVIEW.md
          short-description: "Teleport Community Edition client (tsh), ready to run without installing it"
```

- [ ] **Step 2: Verify the YAML parses and the guards are exact negations**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/build.yml')); print(sorted(d['jobs'])); print(d['jobs']['build']['steps'][2]['if']); print(d['jobs']['build']['steps'][4]['if'])"
```

Expected: `['build', 'description']`, then the build-and-test condition
`github.event_name == 'pull_request' || github.ref != 'refs/heads/master'`, then
the push condition `github.event_name != 'pull_request' && github.ref ==
'refs/heads/master'`. Read them together and confirm every event matches exactly
one of the two — a run that matches neither would pass while doing nothing.

- [ ] **Step 3: Verify the pinned action SHA matches the sibling repo**

```bash
grep -n 'dockerhub-description@' \
  ~/projects/container-terraform/primary/.github/workflows/build.yml \
  .github/workflows/build.yml
```

Expected: the same 40-character SHA in both files. A mismatch means the SHA was
transcribed wrong — correct it from the sibling rather than from memory.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build and smoke-test on PRs, publish from master"
```

---

### Task 5: Repository CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

**Interfaces:**
- Consumes: the target names from Task 3 and the workflow from Task 4.
- Produces: nothing other tasks consume.

- [ ] **Step 1: Write `CLAUDE.md`**

Model it on `~/projects/container-terraform/primary/CLAUDE.md` — guidance for
someone arriving with no context, not a feature list. It must contain these
sections, and every command in it must be one that was actually run in Tasks 2–4:

1. **Build and test** — `make help`, `make build`, `make test`, `make clean`,
   `make push`. State plainly that `make test` is the entire test story: there is
   no lint step and no unit suite, it runs offline, and it cannot verify a login
   because that needs a cluster, a password and a second factor.
2. **Publishing** — images go to `docker.io/pdutton/teleport-client`; `REGISTRY`
   overrides it; every local reference goes through `LOCAL_IMAGE` and no bare
   `$(IMAGE)` may be reintroduced as an image reference; the four-tag scheme
   lives in `TAG_SET_SH` and is expanded by both `tag` and `push`; there is no
   `ubuntu` tag and why (D9).
3. **How the version is pinned** — reproduce the three-places table from D4
   verbatim (`ARG TELEPORT_VERSION` / `TELEPORT_VERSION` / `README.md`, with only
   the first two cross-checked), and state that editing one of the first two
   alone breaks `make test` rather than `podman build`, which is the safety net
   working. Note that there is no release index for Teleport (M2), so pinning is
   not a stylistic difference from the siblings — it is forced.
4. **Licensing** — this repo's code is AGPL-3.0-only, deliberately diverging from
   the GPL-3.0-or-later siblings; the shipped binary is under the Teleport
   Community Edition License, which is neither AGPL nor stock Apache-2.0; the
   image label is `LicenseRef-Teleport-Community-Edition`; the licence file must
   keep travelling inside the image because §4(a) requires it, and the smoke test
   guards that. Point at M5 in the spec for the quoted text.
5. **Design docs** — point at
   `docs/superpowers/specs/2026-08-12-teleport-client-image-design.md` as the
   authority for image shape, version pinning, tags and licensing, and at
   `docs/superpowers/plans/2026-08-12-teleport-client-image.md` for how it was
   built.
6. **Sibling repos** — `~/projects/container-ansible/primary/` and
   `~/projects/container-terraform/primary/` share the build conventions this
   repo follows; `~/projects/teleport/primary/` holds the cluster this client
   talks to, with `SETUP-CLIENT.md` as the authority for cluster-side user
   creation and MFA enrollment.

- [ ] **Step 2: Verify every command in it actually works**

```bash
grep -oE '^\s*(make|podman) [a-z -]+' CLAUDE.md | sort -u
```

Run each one that is not `make push` (which needs registry credentials) and
confirm it behaves as the document claims.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add repository CLAUDE.md"
```

---

### Task 6: README and Docker Hub overview

**Files:**
- Create: `README.md` (replacing the two-line stub from the initial commit)
- Create: `DOCKERHUB-OVERVIEW.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: `DOCKERHUB-OVERVIEW.md`, which Task 4's `description` job publishes.

The two documents deliberately do not cross-check: the overview addresses someone
who landed on the image without the repo. A change to the tag scheme or the alias
must be applied to both by hand, and both must carry the eligibility notice.

- [ ] **Step 1: Write `README.md`**

Required sections, in order. Every command shown must have been run in an earlier
task:

1. **Title and one-line description**, plus the CI badge:
   `[![build](https://github.com/pdutton/container-teleport-client/actions/workflows/build.yml/badge.svg)](https://github.com/pdutton/container-teleport-client/actions/workflows/build.yml)`
2. **Licensing and eligibility** — near the top, not buried at the bottom. This
   paragraph is the one piece of prose in the repo that must be exact, so use it
   verbatim:

   > **Teleport Community Edition is not licensed to everyone.** The Teleport
   > Community Edition License grants its rights only to an individual, or to an
   > organization with fewer than 100 employees *and* less than $10,000,000 in
   > annual revenue. Section 2 of that licence makes this an express condition:
   > "If the conditions of this License are not met, no grant of license under
   > this Section 2 exists." If your organization is over either threshold, you
   > have no licence to use this image. A copy of the licence ships inside the
   > image at `/usr/share/doc/teleport/LICENSE-community`.

3. **Log in and connect (goal 1)** — the alias and the two commands from D7,
   including that `-ti` is required because `tsh login` needs a real terminal for
   the password and MFA prompts and will not accept a pipe. Note that `~/.tsh` is
   shared with any `tsh` on the host, so a `tsh logout` in the container logs the
   host out too. Point at `~/projects/teleport/primary/SETUP-CLIENT.md` for
   creating the user and enrolling a second factor.
4. **Tunnelling a port (goal 2)** — both invocations from D8, host networking
   first, with the `-N` explanation and the caveat that the published-port form's
   `0.0.0.0` bind inside the container is reachable by anything else on that
   container network. State that no VNC client is in the image; the viewer runs
   on the host.
5. **Persisting the identity** — the bind-mount as documented default, the named
   volume as the isolated alternative, and why a non-root user was rejected
   (`--userns=keep-id`, and the confusing failure when it is missing).
6. **Image contents** — the table of what is in and what is deliberately out
   (`tctl`, `teleport`, `tbot`, `openssh-client`, `curl`, `wget`), with sizes:
   `tsh` 134 MB, `tctl` 111 MB, `teleport` 373 MB. Show how to add
   `openssh-client` in a derived image for anyone who wants `tsh proxy ssh` as an
   OpenSSH `ProxyCommand`.
7. **Published images and tags** — the four tags with what each resolves to;
   that every tag is mutable, version tags included, and pinning by digest is the
   only reproducible reference; that the version is pinned and therefore a
   Teleport patch release reaches this image only when someone bumps it —
   naming 18.10.4 explicitly, and noting this is the one place the version is
   written that nothing cross-checks (D4).
8. **Why the version is pinned rather than resolved** — summarise M2 with the
   evidence: the GitHub releases API does not list 18.10.4 although the CDN
   serves it, and no update channel answers for the self-hosted line. Also state
   the D6 limitation plainly: the `.sha256` comes from the same host as the
   tarball, so the build verifies integrity and not authenticity.
9. **Building locally** — `make build`, `make test`, `make clean`, `make push`,
   `make build PODMAN_BUILD_FLAGS="--pull"`; that `push` depends on `test` so a
   failing smoke test blocks the publish; that publishing needs
   `podman login docker.io` first; and that `make clean` leaves the `<none>`
   layer behind, cleared with `podman image prune`.
10. **Continuous integration** — PR builds versus master publishes, the two
    required secrets, that there is no scheduled rebuild, and the Docker Hub
    overview page being generated from `DOCKERHUB-OVERVIEW.md` (so editing it in
    the web UI is overwritten on the next push to `master`).
11. **License** — this repo's own code is AGPL-3.0-only, the `LICENSE` file holds
    that text; the shipped binary is under the Teleport Community Edition
    License, an Apache-2.0 derivative that is neither AGPL nor stock Apache-2.0;
    the image label is `LicenseRef-Teleport-Community-Edition`; Teleport's source
    is at `github.com/gravitational/teleport`. Both licences must be complied
    with, and the eligibility limit above is part of that.
12. **Planned** — multi-arch builds. The build maps `uname -m` to the right
    download so it is correct on whatever host runs it, but no multi-arch
    manifest is published.

- [ ] **Step 2: Write `DOCKERHUB-OVERVIEW.md`**

Shorter, for someone who arrived without the repo. Required content:

1. Title `# pdutton/teleport-client` and a one-line description.
2. **The eligibility paragraph from Step 1, verbatim.** Someone pulling from
   Docker Hub may never see the README, and this is the disclosure that decides
   whether they may use the image at all.
3. Usage: the `tsh` alias with the `~/.tsh` bind mount, `tsh login`, `tsh ssh`.
4. The tunnel recipe, host-networking form only, with a pointer to the repo for
   the isolated alternative.
5. The four tags in a small table.
6. A `## Source` section linking
   `https://github.com/pdutton/container-teleport-client`.
7. An `## Intended Audience` section in the spirit of the sibling repos' —
   personal use and learning are welcome, please share derived images' source,
   this repo's code is AGPL-3.0-only, and the Teleport binary carries its own
   licence with the eligibility limit, so both must be complied with.

- [ ] **Step 3: Verify every command in both documents runs**

Extract and run each `podman` and `make` invocation that does not require cluster
credentials or a registry login:

```bash
grep -hoE '^(podman|make|alias) .*' README.md DOCKERHUB-OVERVIEW.md | sort -u
```

For each `podman run ... tsh <cmd>` line, run the non-interactive part (e.g.
`tsh version`, `tsh --help`) and confirm it works. A README command that has
never been run is the most common defect in this family of repos.

- [ ] **Step 4: Verify the eligibility paragraph appears in both files**

```bash
grep -c "fewer than 100 employees" README.md DOCKERHUB-OVERVIEW.md
```

Expected: `1` for each. This is the one duplication in the repo that is required
rather than tolerated.

- [ ] **Step 5: Commit**

```bash
git add README.md DOCKERHUB-OVERVIEW.md
git commit -m "docs: document usage, tags, tunnelling and licence eligibility"
```

---

### Task 7: End-to-end verification against the live cluster

**Files:** none — this task changes nothing and commits nothing.

**Interfaces:**
- Consumes: the published or locally built image from Tasks 2–3.
- Produces: the evidence that both goals are actually met.

**This task cannot be completed by an agent.** `tsh login` requires a password
and a second factor at an interactive terminal, so a human runs these commands.
The smoke test deliberately covers none of this (D9), which means nothing else in
the repo proves the image does its job.

- [ ] **Step 1: Log in through the container**

```bash
cd ~/projects/container-teleport/feature/initial-image
make build
podman run -ti --rm -v "$HOME/.tsh":/root/.tsh \
  localhost/teleport-client:latest \
  tsh login --proxy=teleport.vikingc1oud.com:443 --user=teleagent
```

Expected: a password prompt, then a second-factor prompt, then a profile summary.
If a stale cached session is in the way, `tsh logout` first — `tsh login` reuses
a still-valid session rather than re-authenticating (`SETUP-CLIENT.md`).

- [ ] **Step 2: Confirm the identity landed on the host**

```bash
ls -la "$HOME/.tsh"
```

Expected: files owned by your host user, not by root and not by a subuid. This is
what D7's rootless-podman UID mapping claim predicts; if ownership looks wrong,
the bind-mount design needs revisiting before the README tells anyone to use it.

- [ ] **Step 3: SSH to the node (goal 1)**

```bash
podman run -ti --rm -v "$HOME/.tsh":/root/.tsh \
  localhost/teleport-client:latest \
  tsh ssh claude@teleport-node
```

Expected: a shell on `teleport-node`. Use the OS login from the user's `logins`
trait, not the Teleport username.

- [ ] **Step 4: Hold a tunnel open (goal 2)**

In one terminal:

```bash
podman run -ti --rm --network=host -v "$HOME/.tsh":/root/.tsh \
  localhost/teleport-client:latest \
  tsh ssh -N -L 5901:localhost:5901 claude@teleport-node
```

In another, with the VNC server running on the node:

```bash
nc -vz localhost 5901
```

Expected: the connection succeeds from the host, with no VNC client inside the
container. Then connect a real viewer to `localhost:5901` and confirm the desktop
appears — a completed TCP handshake proves the forward is listening, not that the
session works.

- [ ] **Step 5: Verify the isolated alternative also works**

```bash
podman run -ti --rm -p 127.0.0.1:5901:5901 -v "$HOME/.tsh":/root/.tsh \
  localhost/teleport-client:latest \
  tsh ssh -N -L 0.0.0.0:5901:localhost:5901 claude@teleport-node
```

Expected: the same result from the host. If this form fails while Step 4 works,
correct the README rather than leaving a documented recipe nobody has run.

- [ ] **Step 6: Record the outcome**

Both goals are now either demonstrated or not. If anything failed, that is a
design defect, not a documentation gap — take it back to the spec before merging.

---

## Post-plan notes

**Merging:** the branch is `feature/initial-image`. Publishing to Docker Hub
happens on merge to `master`, and needs the `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN` repository secrets to exist on
`github.com/pdutton/container-teleport-client` — confirm they are set before
merging, or the first publish fails at `podman login`.

**Deliberately not in this plan:** any change to `~/projects/teleport/primary/`.
M1 answers that repo's curl-vs-wget TODO for the container case, but whether to
update `SETUP-CLIENT.md` is a separate decision in a separate repo.
