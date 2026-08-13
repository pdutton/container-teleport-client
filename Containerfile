# Declared once, before any FROM, so it is global and both stages take it into
# scope with a bare `ARG TELEPORT_VERSION`: the downloader builds the URL from
# it and the final stage's description label interpolates it, so the published
# label cannot advertise a version the image is not on. The admin variant
# overrides that label from the command line instead (see below), so for that
# one image the same guarantee comes from `make test` rather than from here.
ARG TELEPORT_VERSION=18.10.4

# ---- stage 1: download and verify -------------------------------------------
# Thrown away entirely. curl never reaches the shipping image -- the Ubuntu base
# has neither curl nor wget (M1), and this stage is the reason it needs neither.
FROM docker.io/library/alpine:3.23 AS downloader

ARG TELEPORT_VERSION

# Per-architecture digest pin, verified against cdn.teleport.dev on 2026-08-12
# for v18.10.4. One ARG is not enough here: the build supports two
# architectures (amd64, arm64), and each gets a different tarball with a
# different digest, so each needs its own pin. This is a *published-bytes*
# check, additional to (not a replacement for) the tarball's own .sha256:
# the .sha256 is fetched from the same host as the tarball in the same breath,
# so it cannot detect a republished tarball under the same version number --
# only a pin recorded by a human on a stated date, independent of whatever the
# CDN serves on a later cache miss, can. Bumping the version means updating
# both of these alongside it (see CLAUDE.md / README.md / `make help`).
ARG TELEPORT_SHA256_AMD64=a94eeaeec21757fc0973b677d96a683d9cf0f534960c2a835504fe64713145bb
ARG TELEPORT_SHA256_ARM64=915baa902be017b4db930ab17cfe61f4821bd1eb531cf9a04b7df18734a0d1e8

# The whole of the tsh/admin variant difference. Both images come off this one
# Containerfile; only the archive members extracted below change (D12). Default
# false, so an unparameterised `podman build .` still produces the tsh-only
# image the default tags point at.
ARG INCLUDE_TCTL=false

RUN apk add --no-cache curl

RUN set -eu; \
# Validated before anything is downloaded, and against the two exact strings
# rather than a truthiness test. A typo'd `TRUE` or `yes` must not fall through
# to the false branch: that would build a tsh-only image which the Makefile
# would then tag and publish as `admin` -- broken in a way nothing downstream
# could notice, since every other assertion about the image would still pass.
    case "${INCLUDE_TCTL}" in \
      true)  tctl_member=teleport/tctl ;; \
      false) tctl_member= ;; \
      *) echo "ERROR: INCLUDE_TCTL must be exactly 'true' or 'false', not '${INCLUDE_TCTL}'" >&2; exit 1 ;; \
    esac; \
    case "$(uname -m)" in \
      x86_64)  arch=amd64 ; arch_arg=TELEPORT_SHA256_AMD64 ; expected="${TELEPORT_SHA256_AMD64}" ;; \
      aarch64) arch=arm64 ; arch_arg=TELEPORT_SHA256_ARM64 ; expected="${TELEPORT_SHA256_ARM64}" ;; \
      *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;; \
    esac; \
# `teleport-`, not `teleport-ent-`: that prefix is the entire difference between
# the Community and Enterprise builds served from this host.
    tarball="teleport-v${TELEPORT_VERSION}-linux-${arch}-bin.tar.gz"; \
    curl -fsSLO "https://cdn.teleport.dev/${tarball}"; \
    curl -fsSLO "https://cdn.teleport.dev/${tarball}.sha256"; \
# Integrity, not authenticity: this checksum is served by the same host as the
# tarball, so on its own it proves only that the download was not corrupted or
# truncated in transit -- not that Teleport authored the bytes, and not that
# they match what was reviewed at pin time. Kept anyway as a cheap first-pass
# sanity check (a transfer error fails here with a clearer message than a
# digest mismatch would); the pin comparison below is what actually binds this
# build to reviewed bytes. No detached signature is published for these
# archives; TLS to cdn.teleport.dev is what carries the trust for the initial
# fetch (D6).
    sha256sum -c "${tarball}.sha256"; \
    actual="$(sha256sum "${tarball}" | awk '{print $1}')"; \
    if [ "$actual" != "$expected" ]; then \
      echo "ERROR: digest mismatch for ${tarball}" >&2; \
      echo "  expected (${arch_arg} in the Containerfile): ${expected}" >&2; \
      echo "  actual (just downloaded):                    ${actual}" >&2; \
      echo "This means one of two things: either TELEPORT_VERSION was bumped" >&2; \
      echo "without updating ${arch_arg} (a stale pin), or cdn.teleport.dev" >&2; \
      echo "served different bytes under the same tarball name (the exact" >&2; \
      echo "republication risk this pin exists to catch). Do not silently update" >&2; \
      echo "the pin without confirming which one happened." >&2; \
      exit 1; \
    fi; \
# Two or three members out of a 217 MB archive: the client, the admin tool when
# INCLUDE_TCTL asked for it, and the licence that section 4(a) requires to
# travel with any redistribution of either (M5). Extract-then-move rather than
# --strip-components, which busybox tar does not reliably support.
#
# ${tctl_member} is deliberately unquoted -- it must vanish entirely, not expand
# to an empty argument tar would reject. It is always *set* (both branches of the
# case above assign it), so `set -u` is satisfied.
    tar -xzf "${tarball}" -C /tmp teleport/tsh teleport/LICENSE-community ${tctl_member}; \
# The binaries land in their own directory so the final stage can copy them as a
# directory and stay ignorant of the variant: `COPY /out/bin/` moves one file or
# two without a second COPY line that would have to be conditional -- which
# Dockerfile syntax cannot express.
    mkdir -p /out/bin; \
    mv /tmp/teleport/LICENSE-community /out/; \
    mv /tmp/teleport/tsh /out/bin/; \
    if [ -n "${tctl_member}" ]; then mv /tmp/teleport/tctl /out/bin/; fi

# ---- stage 2: the image -----------------------------------------------------
FROM docker.io/library/ubuntu:26.04

ARG TELEPORT_VERSION

# The description names the tsh-only variant, because `LABEL` cannot branch on a
# build arg -- Dockerfile syntax has no conditionals. The admin build therefore
# overrides this one label from the `podman build` command line, alongside the
# `created` and `revision` labels the Makefile already sets there. `make test`
# asserts the resulting value for both variants.
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

# A directory copy, not a per-binary one: /out/bin holds tsh alone, or tsh and
# tctl, depending on INCLUDE_TCTL, and this line does not need to know which.
COPY --from=downloader /out/bin/ /usr/local/bin/
COPY --from=downloader /out/LICENSE-community /usr/share/doc/teleport/LICENSE-community

WORKDIR /apps
CMD ["tsh", "--help"]
