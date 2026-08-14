#!/bin/sh
set -eu

: "${EXPECT_VERSION:?EXPECT_VERSION must be set}"
: "${EXPECT_TCTL:?EXPECT_TCTL must be set to yes or no}"
: "${EXPECT_ARCH:?EXPECT_ARCH must be set to amd64 or arm64}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Checked here rather than trusted, and against the two exact strings: an
# unrecognised value must not fall through to the `no` branch, which would turn
# the admin variant's whole reason for existing into an assertion that tctl is
# absent -- and pass.
case "$EXPECT_TCTL" in
  yes|no) ;;
  *) fail "EXPECT_TCTL is '$EXPECT_TCTL', expected exactly 'yes' or 'no'" ;;
esac

# Same exact-match rule as EXPECT_TCTL above, for the same reason (D13): a value
# that fell through to a wrong branch would turn this assertion into a pass, and
# the whole point of it is to catch a --platform that went missing.
case "$EXPECT_ARCH" in
  amd64|arm64) ;;
  *) fail "EXPECT_ARCH is '$EXPECT_ARCH', expected exactly 'amd64' or 'arm64'" ;;
esac

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

# (c) The exclusions are contract, not accident (D5). teleport and tbot were
# never copied in; curl and wget are absent because the download happens in a
# stage that is discarded (D2), and the Ubuntu base ships neither (M1). tctl is
# handled separately below, since which side of this list it belongs on is the
# one thing that differs between the two variants.
for b in teleport tbot curl wget; do
  ! command -v "$b" >/dev/null 2>&1 || fail "$b is present; it must not be"
done

# (c2) tctl, asserted in both directions (D12). The admin variant exists only to
# carry it, so its absence there is a silent product defect; the default variant
# is the smaller image people get without asking, so its presence there is an
# unannounced ~100 MB and an admin tool nobody requested. Version is checked too:
# tsh and tctl come out of the same tarball and disagreeing would mean the
# extraction pulled members from somewhere unexpected.
if [ "$EXPECT_TCTL" = yes ]; then
  { [ -f /usr/local/bin/tctl ] && [ -x /usr/local/bin/tctl ]; } \
    || fail "/usr/local/bin/tctl is missing or not executable, but EXPECT_TCTL=yes"
  tctl_version="$(tctl version | awk 'NR==1{print $2}')"
  tctl_version="${tctl_version#v}"
  echo "tctl version: $tctl_version"
  [ "$tctl_version" = "$EXPECT_VERSION" ] \
    || fail "tctl is $tctl_version, expected $EXPECT_VERSION"
else
  ! command -v tctl >/dev/null 2>&1 \
    || fail "tctl is present, but EXPECT_TCTL=no; this variant must ship tsh alone"
fi

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

echo "PASS: teleport-client $version smoke test ok (tctl expected: $EXPECT_TCTL)"
