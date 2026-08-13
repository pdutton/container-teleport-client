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
# it, or swap in the wrong file, with nothing a user does ever revealing the
# loss -- non-empty alone is not enough, since `tsh` itself or this repo's own
# AGPL LICENSE are also non-empty and would pass a size-only check. Grep for
# text that only the Community Edition licence contains.
grep -q "Teleport Community Edition License" /usr/share/doc/teleport/LICENSE-community \
  || fail "/usr/share/doc/teleport/LICENSE-community is missing, empty, or does not contain the Teleport Community Edition License text"

# (f) /root/.tsh is the mount point README tells people to bind their identity
# to (D7), so assert the image actually presents it rather than assuming.
[ "${HOME:-}" = /root ] || fail "HOME is '${HOME:-}', expected /root"
mkdir -p "$HOME/.tsh" || fail "$HOME/.tsh could not be created"
: > "$HOME/.tsh/.smoke-probe" || fail "$HOME/.tsh is not writable"
rm -f "$HOME/.tsh/.smoke-probe"

echo "PASS: teleport-client $version smoke test ok"
