# Teleport Client Image — Shape, Build, Tags, Usage

**Written:** 2026-08-12
**Repo:** `container-teleport-client` (GitHub), checked out under
`~/projects/container-teleport/` in the worktree layout
**Status:** design approved, implementation plan to follow

This spec settles what this repo builds, how the build works, how it is tagged
and published, and what the two usage goals look like from the command line. It
is the first design document in this repo; nothing is carried over.

---

## Goals

1. `tsh login` to a Teleport cluster and `tsh ssh` to a node through it, from a
   container, on a host with no Teleport client installed.
2. Hold open a `tsh ssh` port forward so a VNC viewer **on the host** can reach a
   VNC server on the remote node.

Non-goals are listed in "Out of scope" at the end.

The tested manual recipe this replaces is the "Installing on Ubuntu" section of
`~/projects/teleport/primary/SETUP-CLIENT.md`, which installs `tsh` and `tctl`
from the CDN tarball onto a clean Ubuntu 26 VM. That document remains the
authority for the *cluster-side* steps (creating a user, the invite URL, MFA
enrollment); this image only replaces the client install.

---

## Measured facts

M1–M5 measured on 2026-08-12 on this machine, `podman 5.8.1` on WSL2. M6 was
added later and carries its own date.

### M1. The Ubuntu base ships no CA store and no download tool

```
$ podman run --rm docker.io/library/ubuntu:26.04 sh -c \
    'ls /etc/ssl/certs/ca-certificates.crt; dpkg -s ca-certificates | head -1'
ls: cannot access '/etc/ssl/certs/ca-certificates.crt': No such file or directory
dpkg-query: package 'ca-certificates' is not installed

$ podman run --rm docker.io/library/ubuntu:26.04 sh -c \
    'for b in tar gzip apt-get dpkg curl wget; do
       printf "%-8s " "$b"; command -v "$b" || echo MISSING; done'
tar      /usr/bin/tar
gzip     /usr/bin/gzip
apt-get  /usr/bin/apt-get
dpkg     /usr/bin/dpkg
curl     MISSING
wget     MISSING
```

(One binary per iteration deliberately: `command -v a b c` inspects only its
first argument in `dash`, so the compact form silently reports on `tar` alone.)

`ca-certificates` must therefore be installed explicitly — `tsh` validates the
proxy's Let's Encrypt certificate and has no bundled trust store.

This also settles the TODO in `SETUP-CLIENT.md` ("consider reworking to use wget
instead of curl since it already exists on a clean ubuntu 26 install"): that
choice exists because a live VM already has one of the two. The container base
has **neither**, so a container build does not have to choose — the download
happens in a stage that is discarded. See D2.

### M2. There is no usable release index for Teleport

```
$ curl -fsS https://updates.releases.teleport.dev/v1/stable/v18/version    → 404
$ curl -fsS https://updates.releases.teleport.dev/v1/stable/oss/version    → 404
$ curl -fsS https://updates.releases.teleport.dev/v1/stable/cloud/version  → v14.4.1
$ curl -fsS https://cdn.teleport.dev/teleport-latest-linux-amd64-bin.tar.gz.sha256 → 404
```

The only endpoint that answers is the `cloud` channel, which reports v14.4.1 and
has nothing to do with the self-hosted community line.

The GitHub releases API is not an index either — it does not list every published
version:

```
$ curl -fsS 'https://api.github.com/repos/gravitational/teleport/releases?per_page=30' \
    | grep tag_name | head -3
    "tag_name": "v18.10.0"
    "tag_name": "v18.10.0-rc.2"
    "tag_name": "v18.10.0-rc.1"

$ curl -fsSI https://cdn.teleport.dev/teleport-v18.10.4-linux-amd64-bin.tar.gz | head -1
HTTP/2 200
```

18.10.4 is served by the CDN and does not appear in the GitHub release list at
all. Any "newest release on the 18 line" resolver built on that API would have
pinned 18.10.0 while believing itself current — worse than an honest hand-pinned
version, because it would look automatic.

This is why the `container-terraform` pattern (resolve the newest release on a
declared minor line at build time) is **not** reproduced here. See D3.

### M3. Binary sizes in the tarball

```
$ tar -tzvf teleport-v18.10.4-linux-amd64-bin.tar.gz | sort -k3 -nr | head -5
-rwxr-xr-x ci/ci 373848808  teleport/teleport
-rwxr-xr-x ci/ci 133824840  teleport/tsh
-rwxr-xr-x ci/ci 110929992  teleport/tctl
-rwxr-xr-x ci/ci 110661816  teleport/tbot
-rwxr-xr-x ci/ci  61735096  teleport/teleport-update
```

`tsh` is 134 MB; `tctl` would add 111 MB — 44% on top of the shipping payload.
The 217 MB download is entirely discarded except for `tsh`.

### M4. `tsh ssh -L` accepts a bind address, and `-N` exists

```
$ tsh ssh --proxy=example.invalid:443 -L 0.0.0.0:5901:localhost:5901 user@node true
ERROR: Get "https://example.invalid:443/webapi/ping": ... no such host

$ tsh ssh --proxy=example.invalid:443 -L bogus user@node true
ERROR: invalid port forwarding spec 'bogus': expected format `80:remote.host:80`
```

The four-part form reaches the network call, so it parses; the malformed spec is
rejected at parse time. Both `[bind:]port:host:port` and `port:host:port` are
therefore valid, which makes the published-port tunnel variant in D8 viable.

`tsh ssh --help` also lists `-N, --[no-]no-remote-exec  Don't execute remote
command, useful for port forwarding` — the tunnel needs no remote shell.

### M5. The distributed binary is under the Teleport Community Edition License, not AGPL

Teleport's AGPL-3.0 applies to the **source** in their repository. The prebuilt
Community binaries — which is what `cdn.teleport.dev` serves and what this image
ships — are under a different licence. `teleport/README.md` in the tarball:

> The remainder of the source code in this repository is available under the
> [GNU Affero General Public License](./LICENSE). Users compiling Teleport from
> source must comply with the terms of this license.
>
> Teleport Community Edition builds distributed on
> http://goteleport.com/download are available under a
> [modified Apache 2.0 license](./build.assets/LICENSE-community).

The tarball carries that licence as `teleport/LICENSE-community`, headed
"Teleport Community Edition License". Three provisions of it bear on this repo:

**Eligibility is a condition of the grant.** "Legal Entity" is redefined as "an
organization that has less than one hundred (100) employees and less than Ten
Million U.S. Dollars ($10,000,000.00) in annual revenue", and §2 closes with:

> For clarity, the requirement that the party exercising this license must be
> either an individual or a Legal Entity is an express condition to the grant of
> the foregoing license. If the conditions of this License are not met, no grant
> of license under this Section 2 exists.

§3 says the same for the patent grant. An individual is covered whatever their
employer's size, so publishing this image is permitted; a puller at a
500-employee company has no grant at all. See D10.

The condition is on who is **exercising** the licence, not on who happens to be
typing the command: the party exercising the licence must itself be an
individual or a qualifying organization. An employee at a 500-employee company
who uses this image for their own, personal purposes is exercising it as an
individual and is covered.

Where that stops being clear-cut — the same employee using it on their
employer's behalf — this spec deliberately reaches **no** conclusion, and
neither do `README.md` and `DOCKERHUB-OVERVIEW.md`. All three state the
condition and refer the reader to their own legal department. An earlier draft
of all three asserted that the employer becomes the exercising party and that
its size and revenue govern; that is a plausible reading, but it is a legal
determination this repo is not the right place to make on a reader's behalf,
and the wording was withdrawn on 2026-08-13.

What the spec still needs from this section is narrower and does survive: an
individual is covered whatever their employer's size, which is what makes
publishing this image permitted for its author (D10).

**Redistribution is permitted, with an attached condition.** §4 allows
reproduction and distribution of the Work "in any medium, with or without
modifications, and in Source or Object form", provided among other things:

> (a) You must give any other recipients of the Work or Derivative Works a copy
> of this License

Shipping `tsh` in a container image is such a distribution, so the licence file
must travel inside the image. See D2 and D9.

**No `NOTICE` file exists.** `tar -tzf ... | grep -i notice` finds nothing, so
§4(d) imposes nothing here.

This corrects an earlier reading of this design that took the binary to be
AGPL-3.0 on the strength of the README's first licence link alone.

### M6. Both halves of a multi-arch build are already available here

Measured 2026-08-14, for D13–D15.

`arm64` binaries run on this machine without any setup step, because
`qemu-user-static` is registered in `binfmt_misc` with the `F` (fix-binary)
flag — the flag that makes the interpreter usable inside a container that does
not contain it:

```
$ cat /proc/sys/fs/binfmt_misc/qemu-aarch64
enabled
interpreter /usr/bin/qemu-aarch64-static
flags: F
```

So `podman build --platform linux/arm64` and `podman run` against the result
both work locally, unaided. `podman manifest` (create/add/push) is present in
the `podman 5.8.1` already recorded above.

On the CI side, this repo is public:

```
$ gh repo view --json visibility,nameWithOwner
{"nameWithOwner":"pdutton/container-teleport-client","visibility":"PUBLIC"}
```

which is the condition GitHub attaches to the free `ubuntu-24.04-arm` runner.
Native `arm64` CI therefore costs nothing here, and neither half of D15 needs a
paid resource or a setup action.

---

## Decisions

### D1. One image, one `Containerfile`, Ubuntu only

Teleport ships glibc-linked binaries and no musl build, so Alpine is not an
option for the *runtime* image and there is no second OS to support. There is
also no development/prerelease channel: this image tracks whatever the cluster
it talks to runs, and a prerelease client has no audience here.

With one OS and one channel there is nothing for a variant axis to vary over, so
the build file is a plain **`Containerfile`** with no extension and no suffix,
and the Makefile has plain targets rather than `%`-pattern rules. This is a
deliberate divergence from `container-ansible` (four variants) and
`container-terraform` (two channels) — those repos need the axis; this one does
not, and carrying the machinery anyway would mean a `VARIANTS` list of length
one, a variant-shape guard protecting against a collision that cannot occur, and
a CI matrix with a single leg.

If a second variant ever becomes real, reintroducing the axis is a mechanical
change against a working repo, and it can be done *then* with a real sibling to
test the generalization against.

**That happened on 2026-08-13 (D12), and the deferral paid off.** With a real
second variant to test against, the axis that came back is narrower than the one
this section declined to build up front: a `VARIANT` variable with a per-variant
settings table and recursive make, still a single `Containerfile` with no
extension, still plain targets and no `%`-pattern rules, and still no CI matrix.
The heading stands with one correction — one `Containerfile`, Ubuntu only, but
now **two images**. The "no second OS" and "no channel" halves are untouched;
what varies is which archive members get extracted.

### D2. Two-stage build; the final image has no download tool

Stage 1 is `alpine:3.23` with `curl`. It resolves the architecture, downloads the
tarball and its `.sha256`, verifies the checksum, and extracts **only**
`teleport/tsh` and `teleport/LICENSE-community` into `/out`. Stage 2 is
`ubuntu:26.04`, installs `ca-certificates` with `--no-install-recommends`, and
copies both in — the binary to `/usr/local/bin/tsh`, the licence to
`/usr/share/doc/teleport/LICENSE-community`.

The licence file is not documentation garnish: §4(a) of the Community licence
requires giving recipients a copy when redistributing, and publishing this image
is a redistribution (M5). It is ~9 KB.

Consequences, all intended:

- No download tool reaches the shipping image: the base has neither `curl` nor
  `wget` (M1) and the build adds neither. (`tar` and `gzip` *are* in the base —
  `dpkg` depends on them — so they stay; the claim is about fetching, not
  unpacking.)
- The 217 MB tarball and the 373 MB `teleport` server binary never occupy a layer
  in the published image.
- Alpine is the downloader base for consistency with `container-terraform`, and
  because it carries `curl` and a working cert store in ~9 MB.

### D3. The version is pinned exactly, at 18.10.4

`ARG TELEPORT_VERSION=18.10.4`, declared **once before the first `FROM`** so it
is global and both stages take it into scope with a bare `ARG TELEPORT_VERSION`.
The description label interpolates it rather than hardcoding a version, so the
published label cannot advertise a version the image is not on.

Pinning, rather than resolving, follows from M2: there is no index to resolve
against. On its own, though, pinning a version number only buys reproducibility
against podman's layer cache — a rebuild on a cache hit serves whatever was
fetched before, but a cache miss (any CI run on a fresh runner, or `--pull`)
re-fetches from `cdn.teleport.dev` and trusts whatever bytes are served under
that version's name at that moment. A republished tarball under the same
version would pass the same-host `.sha256` check unnoticed. The per-architecture
digest pin (D6) is what closes that gap: with it, a rebuild always produces the
same `tsh`, because the build refuses to proceed on anything but the exact bytes
a human reviewed and recorded on a stated date.

The cost is that nothing announces a new patch release. Bumping is a deliberate
edit to four things, not one — `TELEPORT_VERSION` in the Makefile,
`ARG TELEPORT_VERSION` in the Containerfile, both per-architecture
`ARG TELEPORT_SHA256_AMD64` / `ARG TELEPORT_SHA256_ARM64` digests in the
Containerfile (D6), and the version named in `README.md` (D4) — and is the
intended way to pick up a Teleport security fix.

18.10.4 is the newest patch on the 18.10 line as of 2026-08-12
(`teleport-v18.10.5-...` returns 404).

### D4. The pin lives in three places, all three cross-checked

| Where | Purpose | Cross-checked? |
|---|---|---|
| `ARG TELEPORT_VERSION` in `Containerfile` | what actually gets downloaded | yes |
| `TELEPORT_VERSION` in `Makefile` | passed to the smoke test as `EXPECT_VERSION` | yes |
| the version in `README.md` | documentation | yes — `make test` greps for it |

The Makefile value is deliberately **not** passed as `--build-arg`. That is not
because doing so would make the assertion vacuous — it would not. `EXPECT_VERSION`
is compared against what the *binary itself reports* (`tsh version`), so even
with a single source of truth for the version number, the assertion would still
verify something real: that the tarball fetched from that URL actually contains
a `tsh` that reports that version, and that the extraction pulled the right
archive member. That is an upstream-correspondence check, not a tautology, and
it would hold regardless of how many independent copies of the version number
exist.

What the split *does* buy, honestly stated: it catches a human editing one file
and not the other. If `--build-arg` fed the Makefile's copy straight into the
Containerfile, a maintainer who bumped only one of the two files could no longer
be caught by `make test` diverging from the build — the two would trivially
agree because they were never independent inputs to begin with. Because they
are independent as written, editing one alone does not break `podman build` —
the image builds fine — it breaks `make test`, which is the safety net working
as designed.

The README copy is no longer an exception: `make test` greps `README.md` for
`$(TELEPORT_VERSION)` and fails loudly if it is absent, so all three copies are
now checked against each other. It is still a plain text search, not a version
parse — it confirms the number appears somewhere in the prose, not that every
sentence mentioning it is accurate.

### D5. Contents: `tsh`, its licence, and a cert store — nothing else

`/usr/local/bin/tsh`, `/usr/share/doc/teleport/LICENSE-community` (D2), and the
`ca-certificates` package. Expected size ≈ 250 MB (112 MB base + 134 MB binary +
certs).

Excluded, each for a reason:

- **`tctl`** — 111 MB (M3) for an administrative tool in a client image. It can
  drive a remote cluster using a `tsh` profile, so this is a real trade, but the
  goals are login, ssh and a tunnel; cluster administration goes through
  `SETUP-CLIENT.md`'s `make ssh` path to the auth server.
  **Superseded by D12 (2026-08-13):** the size argument held, but "excluded
  everywhere" was the wrong conclusion to draw from it. `tctl` now ships in a
  separate `admin` variant. This paragraph's reasoning survives intact as the
  reason the *default* image is still `tsh`-only.
- **`teleport`** (the server) — 373 MB, and `SETUP-CLIENT.md`'s verification step
  explicitly asserts `which teleport` finds nothing on a client.
- **`tbot`**, **`teleport-update`** — machine identity and self-update, neither
  of which applies to a pinned client image.
- **`openssh-client`** — `tsh ssh` speaks the protocol itself and needs no `ssh`
  binary; the tunnel in D8 is pure `tsh`. Anyone wanting `ssh`, `scp` or
  `tsh proxy ssh` as an OpenSSH `ProxyCommand` can add it in a derived image, and
  the README says so.

`WORKDIR /apps` and `CMD ["tsh", "--help"]` follow the sibling convention.

### D6. Integrity is verified; authenticity is not, and the README says so

The build downloads `teleport-v${VERSION}-linux-${arch}-bin.tar.gz` and the
matching `.sha256` from `cdn.teleport.dev`, runs `sha256sum -c`, and then
compares the tarball's digest against a **per-architecture pinned digest**
recorded as an `ARG` in the Containerfile (`TELEPORT_SHA256_AMD64` /
`TELEPORT_SHA256_ARM64`), refusing to proceed on a mismatch.

**The same-host `.sha256` alone is served by the same host as the tarball**, so
on its own it proves only that the download was not corrupted in transit or
truncated — not that Teleport authored the bytes, and not that the bytes are
the same ones served under this version number yesterday. A republished
tarball under the same version would pass that check unnoticed on every cache
miss. The pinned digest closes that specific gap: it is a value a human
verified against `cdn.teleport.dev` on a stated date (2026-08-12, for v18.10.4)
and recorded independent of whatever the CDN serves later, so a later
republication under the same name is caught rather than silently accepted.

**This still is not authenticity.** The pin binds the build to bytes a human
looked at on that date — it does not establish that Teleport authored those
bytes, because the pin itself was taken from the same unsigned CDN download it
now protects against *future* substitution. Teleport publishes no detached
signature for these tarballs; the only GPG-verified distribution path is the
apt repository, which was considered and rejected (it requires a published
suite for Ubuntu 26.04's codename, it installs the full server package to
extract one binary from, and it reintroduces exactly the resolve-at-build-time
non-reproducibility D3 exists to avoid). TLS to `cdn.teleport.dev`, at pin time,
is what carried whatever trust exists in the original bytes.

This is a weaker guarantee than `container-terraform`'s pinned-GPG-key
verification. It is stated plainly in the README rather than dressed up, because
a checksum step *looks* like signature verification to a reader skimming the
Containerfile. The digest pin narrows the gap (it defeats silent republication)
without closing it (it still cannot prove authorship).

The URL prefix is `teleport-`, not `teleport-ent-`. That is the entire difference
between Community and Enterprise here, so it gets a comment at the download line.

### D7. Identity persists by bind-mounting the host's `~/.tsh`

The image runs as root with `HOME=/root` and mounts nothing itself. The
documented invocation is `-v "$HOME/.tsh":/root/.tsh:z`.

Under rootless podman, container-root maps to the invoking user's host UID, so
the bind mount's ownership and `tsh`'s own `0700` permission checks line up with
no `--userns=keep-id` and no `chown`. One identity is shared between the
container and any `tsh` on the host: log in once, use either.

**The `:z` suffix is required, and this spec originally omitted it.** Ownership
is not the only thing that can deny access: on a host running SELinux in
enforcing mode, an unlabelled bind mount is denied outright and the first login
fails with `mkdir /root/.tsh/keys: permission denied` — a message that reads
like a file-permission problem rather than a labelling one. `:z` applies a
shared container label, keeping the directory usable from both the container and
the host's own `tsh`; `:Z` would take it away from the host, and neither belongs
anywhere near `$HOME` itself.

The omission survived every review because all verification ran on WSL2, where
SELinux is not enforcing, so the unlabelled mount worked here and would have
failed for every Fedora/RHEL user. The `Makefile` had `,z` on its own test mount
the whole time — the inconsistency between the two was visible in the repo and
still went unnoticed. Reported from a real SELinux host on 2026-08-13 and fixed
the same day.

A named volume needs no suffix: podman labels volumes it creates itself.

The trade-off is that a `tsh logout` inside the container also logs the host out.
That is the correct behaviour for a *shared* identity and is documented, not
worked around.

A named volume is documented as the alternative for anyone wanting isolation. A
non-root user was rejected: bind-mounting the host's `~/.tsh` would then need
`--userns=keep-id`, and getting it wrong produces a `tsh` permission error that
reads like a `tsh` bug rather than a mount problem.

`podman run -ti` is required, not cosmetic — `tsh login` needs a real terminal
for the password and MFA prompts and will not accept a pipe. `SETUP-CLIENT.md`
records the same constraint for scripting (drive it through a pty).

### D8. The tunnel is documented two ways, host networking first

Host networking, the quick path:

```bash
podman run -ti --rm --network=host -v "$HOME/.tsh":/root/.tsh:z \
  docker.io/pdutton/teleport-client:latest \
  tsh ssh -N -L 5901:localhost:5901 claude@teleport-node
```

The container shares the host's network namespace, so `tsh`'s default 127.0.0.1
bind *is* the host loopback and a viewer connects to `localhost:5901` with
nothing further configured. The forward stays on loopback, not the LAN. The cost
is no network isolation at all.

Isolated namespace, the alternative:

```bash
podman run -ti --rm -p 127.0.0.1:5901:5901 -v "$HOME/.tsh":/root/.tsh:z \
  docker.io/pdutton/teleport-client:latest \
  tsh ssh -N -L 0.0.0.0:5901:localhost:5901 claude@teleport-node
```

Only the one port crosses the namespace boundary. Two caveats are documented: the
port is named twice in two different syntaxes, and the `0.0.0.0` bind inside the
container is reachable by anything else on that container network.

`-N` (M4) holds the forward open without starting a remote shell.

No VNC client ships in the image. The viewer runs on the host; the container's
only job is to carry the port.

### D9. Tags, and the offline smoke test

Four tags, all derived by reading `tsh version` back out of the freshly built
image so they cannot drift from what is installed:

`latest` · `18` · `18.10` · `18.10.4`

**Extended by D12 (2026-08-13):** ten tags now, across two variants. The
readback mechanism is unchanged, and these four still name the `tsh`-only image.

**Extended by D13–D14 (2026-08-14):** these ten names now label *manifest
lists* rather than images, and four arch-suffixed image tags sit beside them.
The count of names a user is meant to pull is unchanged, and the readback
mechanism survives again.

There is no `ubuntu` tag. With a single image it would be a permanent alias of
`latest` — a second name meaning exactly the same thing, to be kept in sync for
no benefit. The base OS is a README fact. (`container-ansible` publishes an
`ubuntu` tag because it also publishes `alpine`; that contrast is what gives the
name meaning there.) A bare major tag `18` is safe here for the same reason it is
unsafe in `container-terraform`: there is one image, so nothing else can claim
it.

Every tag is mutable, version tags included — a rebuild of 18.10.4 re-pushes the
same name over a new digest. Pin by digest for reproducibility.

`test/smoke.sh` runs entirely offline inside the built image, with
`EXPECT_VERSION` supplied by the Makefile (D4). It asserts:

- `/usr/local/bin/tsh` exists and is executable — the path is the contract for
  anyone building `FROM` this image or `COPY --from`ing out of it, so it is
  asserted directly rather than inferred from `tsh` being on `PATH`
- `tsh version` reports exactly `EXPECT_VERSION`
- `teleport`, `tctl`, `tbot`, `curl` and `wget` are all absent from `PATH` (D2,
  D5 — the exclusions are contract, not accident). **Amended by D12:** `tctl`
  moved out of this list and is now asserted in both directions, driven by
  `EXPECT_TCTL` — absent in the default variant, present and reporting the
  pinned version in the `admin` one.
- `/etc/ssl/certs/ca-certificates.crt` exists (M1)
- `/usr/share/doc/teleport/LICENSE-community` exists and contains text unique to
  that licence (`grep -q "Teleport Community Edition License"`), not merely
  that it is non-empty. This is the one assertion here that protects a licence
  obligation rather than a feature: §4(a) requires the copy to reach recipients
  (M5), and non-empty alone is too weak a check — `tsh` itself, or this repo's
  own AGPL `LICENSE`, are also non-empty and would pass a size-only check if a
  refactor of the `COPY --from` lines put either at that path by mistake
- `$HOME` is `/root`, and `$HOME/.tsh` can be created and written — this is the
  mount point the README instructs people to bind (D7)

It cannot verify a login: that needs a cluster, a password and a second factor.
No network probe is included, so an upstream outage cannot turn the build red.
Verifying the two goals end to end is a manual step after a version bump.

`test/smoke.sh` runs inside the built image and cannot see image labels, so two
further checks live in the Makefile's `test` recipe instead, run against the
image from the outside via `podman image inspect`: that
`org.opencontainers.image.licenses` is exactly
`LicenseRef-Teleport-Community-Edition` (D10), and that
`org.opencontainers.image.description` contains the pinned version — i.e. that
the label actually interpolates `TELEPORT_VERSION` rather than a hand-typed
string that could drift from it (D3). The same `test` recipe also greps
`README.md` for the pinned version (D4).

### D10. Licensing: repo AGPL-3.0-only, image labelled `LicenseRef-Teleport-Community-Edition`

Two licences are in play and they cannot be collapsed into one.

**This repo's own code** — Containerfile, Makefile, smoke test, docs — is
**AGPL-3.0-only**. This diverges from `container-ansible` and
`container-terraform`, which are GPL-3.0-or-later; the choice is deliberate,
aligning this repo with the licence on Teleport's own source repository rather
than with its siblings. The `LICENSE` file holds the AGPL-3.0 text, and unlike
the siblings there is no "or later" election to make in the README.

**The binary the image ships** is under the Teleport Community Edition License
(M5), which is neither AGPL nor stock Apache-2.0. SPDX has no identifier for it,
so the image carries:

```
org.opencontainers.image.licenses="LicenseRef-Teleport-Community-Edition"
```

`LicenseRef-` is SPDX's own escape hatch for licences without an identifier,
which keeps the label a valid SPDX expression instead of free text an automated
scanner would choke on. Labelling it `AGPL-3.0-only` would misdescribe the
contents; labelling it `Apache-2.0` would understate the conditions.

The label describes only the Teleport Community Edition licence, even though
the image also contains Ubuntu base packages (their own, various, licences) and
the Mozilla CA bundle shipped inside `ca-certificates` (MPL-2.0). Describing
only the primary payload in a single-value licence label is conventional
practice — OCI's own `image.licenses` label is documented as a best effort, not
an exhaustive bill of materials, and most published images with a bundled base
OS do the same — so the omission of the base image's and CA bundle's licences
here is a decision, not an oversight.

**The eligibility limit is the disclosure that matters.** README and
`DOCKERHUB-OVERVIEW.md` must both state, prominently and in their own words, that
Teleport Community Edition is licensed only to individuals and to organizations
with fewer than 100 employees and under $10M annual revenue — and that outside
those bounds no grant exists, so the image cannot be used. This gets the same
treatment `container-terraform` gives its BUSL note: stated plainly, not buried
in a licence section at the bottom.

The README also points at `github.com/gravitational/teleport` for source, and
notes that the licence file travels inside the image at
`/usr/share/doc/teleport/LICENSE-community`, so anyone redistributing a derived
image inherits a copy and satisfies §4(a) by default.

None of this is legal advice; it is a reading of the licence text quoted in M5,
recorded so the next person can check it against the same source.

### D11. Repo layout, publishing, CI

```
Containerfile
Makefile
test/smoke.sh
.github/workflows/build.yml
README.md
DOCKERHUB-OVERVIEW.md
CLAUDE.md
.dockerignore
.gitignore
LICENSE
```

Published to **`docker.io/pdutton/teleport-client`**. The `-client` suffix is
load-bearing: `pdutton/teleport` would read as a cluster image to anyone browsing
Docker Hub, and would claim the obvious name that a future server or agent image
should get.

The Makefile keeps the sibling conventions that are not variant machinery:
`LOCAL_IMAGE = localhost/$(IMAGE)` used for every local reference (a bare short
name can resolve to a non-localhost repo, and the push source must not depend on
that tie-break); `TAG_SET_SH` expanded by both `tag` and `push` so the tag scheme
is written once (by `tag-variant` and `push-variant` since D12, switching on
`$(VARIANT)` — still one definition); the version-readback tagging pass; `push` depending on `test` so
a failing smoke test blocks the publish; and a `clean` scoped to this repo's own
tags.

`.github/workflows/build.yml` mirrors the siblings without the matrix: build and
smoke-test on pull requests, publish only from `master` (a `workflow_dispatch`
against another branch still builds and tests but publishes nothing), and a
separate `dockerhub-description` job — `needs: build`, master-only, pinned to a
commit SHA because it is a third-party action handling a write-scoped token —
that syncs `DOCKERHUB-OVERVIEW.md` to the Hub page.

**Extended by D15 (2026-08-14):** `build` does gain a matrix after all, over
architecture rather than variant, and a third job (`manifest`) lands between
`build` and `dockerhub-description`.

### D12. `tctl` ships in a second variant, gated on one build arg

**Added 2026-08-13, after the v1.0.0 release.** This reverses part of D5 and
extends D9; both are annotated below rather than rewritten, so the original
reasoning and what overtook it stay legible.

`tctl` is now available, but not in the default image. One `Containerfile`
produces two images, separated by a single build arg:

| Variant | Contents | Size | Tags |
|---|---|---|---|
| `tsh` (default) | `tsh` | 257 MB | `latest` `tsh` `18` `18.10` `18.10.4` |
| `admin` | `tsh` + `tctl` | 368 MB | `admin` `tctl` `18-admin` `18.10-admin` `18.10.4-admin` |

**Why not a second `Containerfile`.** The whole difference is which members
`tar` extracts. A second file would duplicate the digest pin, the architecture
`case`, the licence copy and the base-image setup — every one of which is
load-bearing, and every one of which would then have to be bumped twice. The
`INCLUDE_TCTL` arg is read only in the downloader stage; the final stage does a
directory copy (`COPY --from=downloader /out/bin/`) and never learns which
variant it is building. That single indirection is what lets `COPY` stay
unconditional, which matters because Dockerfile syntax has no conditionals at
all.

**Why the default stays `tsh`-only.** 111 MB, for a tool that neither of the two
goals in this document needs. Reversing the default would push that cost onto
every user who only wants to log in and hold a tunnel open — the majority — to
spare a pull for the minority who administer the cluster. The `admin` variant is
a superset rather than a `tctl`-only image, so nobody who wants both has to pull
twice.

**Why the arg is validated against exact strings.** `INCLUDE_TCTL` accepts only
`true` or `false`, and fails the build before the download otherwise. A truthiness
test would let `TRUE` or `yes` fall through to the false branch and build a
`tsh`-only image that the Makefile would then tag and publish as `admin`. Nothing
downstream could catch it: every other assertion about that image still passes.
`EXPECT_TCTL` in the smoke test is validated the same way, for the same reason —
a value that fell through to `no` would turn the admin variant's reason for
existing into an assertion that succeeds.

**Why the smoke test asserts `tctl` in both directions.** Presence in the admin
variant and absence in the default one are each the only check that would catch
their own failure. An accidental inclusion is an unannounced 111 MB and an admin
tool in the image people get without asking; an accidental omission leaves the
`admin` tag published and useless.

**What is *not* verified.** `tctl version` runs offline, so that is all CI can
assert. Whether `tctl` can actually administer a cluster needs a live auth
server and a privileged role, and stays a manual step alongside `tsh login` and
the tunnel (D9's closing note already says this about the client).

**The `tsh` and `tctl` tags are aliases**, of `latest` and `admin` respectively.
D9 rejects an `ubuntu` tag as a permanent alias earning nothing, and that
argument still holds for `ubuntu` — but it turns on contrast, not on aliasing as
such. `container-ansible`'s `ubuntu` tag earns its keep because `alpine` sits
beside it. `tsh` earns its keep the same way, because `tctl` now does. There is
still no `ubuntu` tag here, because there is still one base OS.

**Makefile shape.** Per-variant values are rows in a table near the top, read
from the recipes as `$(<SETTING>_$(VARIANT))`; each plain target re-invokes make
once per variant against a `-variant` target that refuses to run with `VARIANT`
unset. Adding a third variant means adding rows, not recipes.

The one thing that could not be single-sourced is
`org.opencontainers.image.description`: `LABEL` cannot branch on a build arg, so
the admin build overrides it from the command line. The `tsh` build deliberately
does not, which is what keeps D4's cross-check comparing two independently
written copies rather than one string against itself.

**CI cost.** The tarball is fetched twice — the variants diverge at exactly the
layer podman's cache would otherwise reuse — so the build job's `timeout-minutes`
went from 20 to 30.

### D13. `amd64` and `arm64`, published as manifest lists; the `Containerfile` does not change

**Added 2026-08-14.** This retires the "No multi-arch manifest" entry from Out
of scope and extends D9 and D11; both are annotated in place rather than
rewritten.

The build has always resolved the architecture correctly — D2's downloader
stage maps `uname -m` to the download, and D6 pins a digest per architecture —
so an `arm64` build has produced a correct `arm64` image since day one. What was
missing was only the publishing half: nothing built the second architecture, and
nothing assembled a manifest list, so a puller on `arm64` got the `amd64` image
under `latest` and no error until the binary failed to execute.

**The `Containerfile` is untouched by this decision.** Under
`podman build --platform linux/arm64` the emulated container reports `aarch64`,
and on a native `arm64` runner it reports `aarch64` too, so the existing `case`
is correct in both halves of D15 without a line changed. That keeps the
`uname -m` idiom shared with `container-terraform` intact and leaves D6's
per-architecture digest pin reading exactly as written.

**Why not `FROM --platform=$BUILDPLATFORM` plus `ARG TARGETARCH`.** It would run
the 217 MB download and extraction natively instead of emulated, which is the
expensive part of a local `arm64` build. But it forces the architecture
detection away from `uname -m` — `uname` would then report the *build* host and
select the wrong tarball — which breaks the family idiom and rewrites the load-
bearing half of D2 and D6 for a speed-up that is worth nothing in CI, where
D15 makes both architectures native anyway. Rejected: the cost lands on the one
place (a local build) where waiting is cheapest.

**Architecture is asserted, not assumed.** `test/smoke.sh` gains `EXPECT_ARCH`,
validated against exactly `amd64|arm64` for the same reason `EXPECT_TCTL` is
validated against exactly `yes|no` (D12) — a value that fell through to the
wrong branch would turn the assertion into a pass. It checks `uname -m` inside
the running image. This is the assertion that catches a `--platform` dropped
from one of the two `podman build` invocations, which would otherwise publish an
`amd64` image under an `arm64` name and satisfy every check that already exists.
The label-stamping build in the tagging pass is the likely place for that to
happen: it currently bypasses `PODMAN_BUILD_FLAGS` entirely, so it needs
`--platform` passed to it explicitly or it re-resolves to the host.

### D14. Four arch-suffixed tags are published beside the ten lists

**Added 2026-08-14.** The ten names of D9/D12 become manifest lists.
`latest-amd64`, `latest-arm64`, `admin-amd64` and `admin-arm64` are published
alongside them as plain images — one per variant per architecture, on the base
tag only, not on all five names.

This is a consequence of D15 rather than a goal. With each architecture built on
its own runner, the two images have to meet somewhere before a list can
reference them, and the registry is the only place they both exist.

**Why not keep the surface at exactly ten.** The alternative is to push each
member to a throwaway tag, record its digest, assemble the lists from digests,
and delete the staging tags through the Docker Hub API afterwards — which is how
`buildx` leaves members untagged. It costs a delete-scoped token, digests
crossing job boundaries as job outputs, and orphaned tags whenever a run is
cancelled. Shipping four honest names instead buys a debugging affordance —
`podman pull …:latest-arm64` fetches one architecture deliberately, which is
exactly what someone diagnosing a bad member wants — and costs one row in the
`DOCKERHUB-OVERVIEW.md` tag table.

The four names are documented as an implementation detail people *may* pull, not
as the supported interface. The ten lists remain what the README tells anyone to
use; pulling `latest` resolves to the right architecture automatically, which is
the entire point of the change.

### D15. Emulation locally, native runners in CI — one parameterised path, not two

**Added 2026-08-14.** A local `make build` produces both architectures on one
machine through the QEMU registration measured in M6. CI builds each
architecture on a runner of that architecture: `ubuntu-latest` and the free
`ubuntu-24.04-arm` that M6 confirms this repo qualifies for.

The obvious risk in having two mechanisms is that they drift, and the answer is
that there is only one mechanism with an input. The Makefile gains `ARCH`
alongside `VARIANT` as a second fan-out dimension, in the same written-out style
D12 chose for variants and for the same reasons — `make -n` stays readable and a
`for` loop in a recipe cannot swallow a non-zero exit. Every unit of work lives
in an `-arch` target keyed on both, guarded by a `REQUIRE_ARCH_SH` mirroring
`REQUIRE_VARIANT_SH` (make expands an unset `$(PLATFORM_)` to nothing and fails
somewhere much less obvious). `podman build --platform` is passed identically in
both halves; on a native runner it is simply a no-op assertion of what the host
already is. What differs between local and CI is only *which* of the four
`(variant, arch)` pairs a given invocation runs — the fan-out, not the recipe.

Two things genuinely cannot be identical, and both are parameters rather than
branches:

**Where the list finds its members.** `manifest-variant` takes `MANIFEST_SRC`,
defaulting to `$(LOCAL_IMAGE)` so a local build assembles from local images, and
set to the registry reference in CI where the members were pushed by two
different runners. Same target, same `TAG_SET_SH`, one input.

**Where the version comes from.** `TAG_SET_SH` needs `$version`, and the CI
`manifest` job has no local image to read it out of. It takes `VERSION` as a
required input: locally the fan-out reads it back off the freshly built member
for free, and in CI it arrives as a job output that the build job emitted after
performing exactly the same readback. No hand-typed version enters the tag
derivation in either half, which is what D9's readback rule actually protects.

A cross-architecture version disagreement cannot slip through unnoticed and does
not need its own check: `test-arch` already asserts each image's `tsh version`
equals `$(TELEPORT_VERSION)` (D4) on both architectures, and `push` depends on
`test`, so the two members are transitively pinned to the same string.

**Failure mode worth naming.** The publish is no longer a single step: arch tags
are pushed by the build jobs, and the lists are pushed by a later job. A run
cancelled between them leaves the four arch tags updated while the ten lists
still point at the previous members. D11's existing
`cancel-in-progress: false` on `master` is what keeps this rare, and re-running
the workflow repairs it. It is a recoverable inconsistency, not a reason to
ship the artifact-shuffling alternative.

**CI cost.** Four builds per run instead of two, but across two runners in
parallel, so wall-clock per job is unchanged from D12's measurement and the
30-minute `timeout-minutes` still holds. Pull requests now get full `arm64`
coverage, natively, which they did not have before.

**Scope.** This repo only. `container-ansible` and `container-terraform` both
list multi-arch under "Planned" and neither has a pattern to copy — this becomes
the family's reference implementation, but porting it is separate work in
separate repos.

---

## Out of scope

- **No development or prerelease channel.** One pinned version.
- **No architecture beyond `amd64` and `arm64`.** Multi-arch manifests were on
  this list until D13–D15 (2026-08-14) published them; the README's "Planned"
  bullet went with them. Teleport does publish two more Linux tarballs —
  `linux-arm` (32-bit) and `linux-386` both answered 200 on `cdn.teleport.dev`
  on 2026-08-14, `linux-riscv64` 404s — but neither is a plausible target for a
  desktop client used to hold open a VNC tunnel (D8), and each would need a
  hand-verified digest pin (D6) maintained across every version bump. Adding one
  later is mechanical: a `case` arm and a digest `ARG` in the `Containerfile`, a
  row in the arch block and a name in `REQUIRE_ARCH_SH` in the Makefile, and a
  runner or emulator that can build it.
- **No server binary, no VNC client** (D5, D8). `tctl` was on this list until
  D12 moved it into the `admin` variant; the server binary and VNC client stay
  out of both.
- **No scheduled rebuild.** A Teleport patch release or an Ubuntu base fix
  reaches the published image only when someone bumps the pin or re-runs the
  workflow.
- **No cluster-side changes.** Creating users, roles and MFA enrollment stay in
  `~/projects/teleport/primary/SETUP-CLIENT.md`.
- **No change to the teleport repo.** M1 resolves that repo's curl-vs-wget TODO
  for the container case only; whether to update `SETUP-CLIENT.md` is a separate
  decision in a separate repo.
