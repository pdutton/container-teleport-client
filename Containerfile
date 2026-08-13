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
