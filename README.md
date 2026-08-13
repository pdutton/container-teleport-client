# container-teleport-client

A container image carrying Teleport Community Edition's `tsh` client, so you can log in to a
Teleport cluster and `ssh` through it without installing anything on the host.

[![build](https://github.com/pdutton/container-teleport-client/actions/workflows/build.yml/badge.svg)](https://github.com/pdutton/container-teleport-client/actions/workflows/build.yml)

## Licensing and Eligibility

**Teleport Community Edition is not licensed to everyone.** The Teleport
Community Edition License grants its rights only to an individual, or to an
organization with fewer than 100 employees *and* less than $10,000,000 in
annual revenue. Section 2 of that licence makes this an express condition:
"If the conditions of this License are not met, no grant of license under
this Section 2 exists." If your organization is over either threshold, you
have no licence to use this image. A copy of the licence ships inside the
image at `/usr/share/doc/teleport/LICENSE-community`.

The condition is on whoever is *exercising* the licence, not on who happens to
type the command: pulling and running this image for your own, personal
purposes is you exercising it as an individual and is covered regardless of
your employer's size, but using it for your employer's benefit is a question to
put to your company's legal department.

## Log in and Connect

```bash
mkdir -p ~/.tsh   # podman does not create a bind mount's source directory for you
alias tsh='podman run -ti --rm -v "$HOME/.tsh":/root/.tsh:z docker.io/pdutton/teleport-client:latest tsh'

tsh login --proxy=teleport.example.com:443 --user=claude   # "claude" here is your Teleport username
tsh ls                                                      # list the nodes you can reach, and their names
tsh ssh claude@teleport-node   # "claude" here is the OS login user on that node -- it can be a
                                # different name from your Teleport username above; they're spelled
                                # the same in this example only because it's convenient, not because
                                # they must match
```

`podman run -ti` is required, not cosmetic: `tsh login` needs a real terminal for the password
and MFA prompts and will not accept a pipe.

This alias is not a full drop-in for a locally installed `tsh`: only `~/.tsh` is mounted and
`WORKDIR` is `/apps`, so subcommands that touch other host files (`tsh scp`, `tsh play` against a
local recording, `--identity` outside `~/.tsh`) will fail, and `-ti` interferes with piping its
output.

`-v "$HOME/.tsh":/root/.tsh:z` bind-mounts your host's Teleport identity into the container. It is
the *same* identity a `tsh` installed directly on the host would use — log in once, from either
side, and both can use the session. The reverse also holds: a `tsh logout` run inside the
container logs the host out too. See [Persisting the Identity](#persisting-the-identity) below
for the isolated alternative.

The `mkdir -p ~/.tsh` above matters on a brand-new host: podman's rootless bind mounts do not
create the source directory for you, so without it the run fails on the very first login with
`statfs ...: no such file or directory`. Harmless to repeat if `~/.tsh` already exists.

The `:z` on the end of the mount matters on any host running SELinux in enforcing mode — Fedora,
RHEL and their derivatives. Without it, the container is denied access to the mounted directory
and the first login fails with `mkdir /root/.tsh/keys: permission denied`, which reads like a
file-permission problem rather than a labelling one. `:z` relabels the directory with a shared
container label, so the container and a `tsh` installed on the host both keep access. It is a
no-op where SELinux is not enforcing, so it is safe to leave in the command everywhere.

Use `:z`, not `:Z`: the uppercase form applies a private per-container label, which takes the
directory away from the host's own `tsh`. And apply either only to a dedicated directory like
`~/.tsh` — a recursive relabel of `$HOME` is destructive and hard to undo.

Creating the cluster user and enrolling a second factor is a cluster-side step this repo does not
cover; see Teleport's own documentation on
[adding local users](https://goteleport.com/docs/zero-trust-access/rbac-get-started/users/) (the
invite link it generates walks a new user through setting a password and enrolling MFA) and the
[`tsh mfa add`](https://goteleport.com/docs/reference/cli/tsh/) reference for adding further
devices later.

## Tunnelling a Port

Goal: hold open a `tsh ssh` port forward so a VNC viewer **on the host** can reach a VNC server on
a remote node. No VNC client ships in this image — the viewer runs on the host, and the
container's only job is to carry the port.

Host networking, the quick path:

```bash
podman run -ti --rm --network=host -v "$HOME/.tsh":/root/.tsh:z \
  docker.io/pdutton/teleport-client:latest \
  tsh ssh -N -L 5901:localhost:5901 claude@teleport-node
```

`-N` holds the forward open without starting a remote shell. With `--network=host` the container
shares the host's network namespace, so `tsh`'s default `127.0.0.1` bind *is* the host loopback —
a viewer connects to `localhost:5901` with nothing further configured. The cost is no network
isolation at all: the container can reach (and be reached on) everything the host can.

Isolated namespace, the alternative:

```bash
podman run -ti --rm -p 127.0.0.1:5901:5901 -v "$HOME/.tsh":/root/.tsh:z \
  docker.io/pdutton/teleport-client:latest \
  tsh ssh -N -L 0.0.0.0:5901:localhost:5901 claude@teleport-node
```

Only the one port crosses the namespace boundary, via `-p`. Two things to notice: the port is
named twice, in two different syntaxes (`podman run -p` and `tsh ssh -L`), and the `0.0.0.0` bind
*inside* the container means the forward is reachable by anything else on that container network,
not just from the host — the `-p 127.0.0.1:...` mapping is what keeps it off the host's other
interfaces.

## Persisting the Identity

The documented default is the bind mount shown above:

```bash
-v "$HOME/.tsh":/root/.tsh:z
```

The image runs as root with `HOME=/root` and mounts nothing itself. Under rootless podman,
container-root maps to the invoking user's host UID, so the bind mount's ownership and `tsh`'s own
`0700` permission checks line up without a `--userns` flag.

Ownership is not the only thing that can deny access, though: on an SELinux host the label matters
too, which is what the `:z` above is for. A named volume needs no such suffix — podman labels
volumes it creates itself.

For an identity isolated from the host's own `tsh`, use a named volume instead:

```bash
-v teleport-client-identity:/root/.tsh
```

A named volume gets its own login, separate from anything on the host.

A non-root container user was considered and rejected: bind-mounting the host's `~/.tsh` into a
non-root container would then require `--userns=keep-id` on every invocation, and forgetting it
produces a `tsh` permission error that reads like a `tsh` bug rather than a missing mount flag.
Running as root, with rootless podman doing the UID mapping, avoids that failure mode entirely.

## Image Contents

| Path | Present |
|---|---|
| `/usr/local/bin/tsh` | yes — 134 MB |
| `/usr/share/doc/teleport/LICENSE-community` | yes |
| `ca-certificates` (`/etc/ssl/certs/ca-certificates.crt`) | yes |
| `teleport` (the server) | no — would add 373 MB |
| `tctl` (cluster admin) | no — would add 111 MB |
| `tbot` (machine identity) | no |
| `curl`, `wget` | no — the download happens in a build stage that is discarded |
| `openssh-client` (`ssh`, `scp`) | no — `tsh ssh` speaks the protocol itself |

The image is built for the two goals above: logging in and tunnelling a port. Cluster
administration (`tctl`) is out of scope for this image — reach the auth server directly (SSH
access to the host it runs on, or Teleport's own
[`tctl` reference](https://goteleport.com/docs/reference/cli/tctl/)) instead, and the server
binary has no place in a client image at all.

If you want `ssh`, `scp`, or `tsh proxy ssh` as an OpenSSH `ProxyCommand`, add `openssh-client` in
a derived image:

```dockerfile
FROM docker.io/pdutton/teleport-client:latest
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*
```

## Published Images and Tags

Published to [`pdutton/teleport-client`](https://hub.docker.com/r/pdutton/teleport-client) on
Docker Hub:

```bash
podman pull docker.io/pdutton/teleport-client:latest
```

| Tag | Resolves to |
|---|---|
| `latest` | the current build |
| `18` | the newest build on the Teleport 18 line published here |
| `18.10` | the newest build on the Teleport 18.10 line published here |
| `18.10.4` | this exact version |

All four are derived by reading `tsh version` back out of the freshly built image, so they cannot
drift from what is actually installed inside it. There is no `ubuntu` tag — with a single base
image it would be a permanent alias of `latest`, a second name for the same thing.

**Every tag is mutable, version tags included.** A rebuild of 18.10.4 re-pushes the same name over
a new digest (a base-image security refresh, for instance). If you need a reproducible reference,
pin by digest:

```bash
podman pull docker.io/pdutton/teleport-client@sha256:<digest>
```

The Teleport version is pinned at **18.10.4**. This is the third of three places that pin appears
in this repo (`Containerfile`, `Makefile`), and `make test` greps this file for the pinned version
to catch a bump that missed it — a version bump here is still a manual edit, but a forgotten one
now fails the build rather than silently going stale. See
[Why the Version Is Pinned](#why-the-version-is-pinned-rather-than-resolved) below for why it is
pinned rather than resolved, and `CLAUDE.md` for the mechanics of bumping it (which also means
updating the two per-architecture digest pins in the Containerfile).

## Why the Version Is Pinned Rather Than Resolved

There is no usable release index for Teleport to resolve a version against at build time.

`updates.releases.teleport.dev` answers only for its `cloud` channel, which has nothing to do with
self-hosted Community Edition. The GitHub releases API is not a substitute either: it does not
list every published version. 18.10.4 is served by `cdn.teleport.dev` and works fine, but it does
not appear in the GitHub releases list at all — a resolver built on that API would have silently
pinned an older release while believing itself current. Pinning by hand, and bumping deliberately,
is more honest than an automatic resolver that can be wrong without telling you.

## Integrity, Not Authenticity

The build fetches the tarball and a matching `.sha256` from `cdn.teleport.dev` and checks the
hash — but that checksum is served by the *same host* as the tarball in the same breath, so on its
own it proves only that the download was not corrupted or truncated in transit, not that Teleport
authored the bytes. A tarball silently republished under the same version name would pass that
check unnoticed on the next cache miss.

The Containerfile also pins an expected SHA-256 digest per architecture (`TELEPORT_SHA256_AMD64`,
`TELEPORT_SHA256_ARM64`), recorded by hand against bytes fetched from `cdn.teleport.dev` on a
stated date, and fails the build loudly if the downloaded tarball's digest does not match. That
closes the republication gap above — a rebuild always fetches and verifies the *same* bytes — but
it is still not authenticity: the pin itself was taken from the same unsigned CDN download it now
protects against future substitution, so it establishes a binding to bytes a human looked at on
that date, not that Teleport authored them. Teleport publishes no detached signature for these
tarballs at all. TLS to `cdn.teleport.dev`, at the time the pin was taken, is what actually carries
whatever trust exists in the original bytes.

## Building Locally

Requires [Podman](https://podman.io/) and GNU Make.

```bash
make build      # build the image and apply the full tag set
make test       # build, then run the offline smoke test
make clean      # remove this repo's four tags
make push       # build, test, then publish every tag (needs registry credentials)

make build PODMAN_BUILD_FLAGS="--pull"   # refresh the Ubuntu and Alpine base images
```

`push` depends on `test`, so a failing smoke test blocks the publish — a broken image cannot reach
the registry through `make push`. Publishing needs `podman login docker.io` first, or the push
fails on its first tag.

`make clean` removes this repo's four tags but leaves the untagged `<none>` layer that the
version-label build step creates behind — `podman rmi` on a tag does not cascade to the image it
was derived from. Clear those with `podman image prune`; `clean` does not run it automatically,
since a blanket prune would also delete images this repo never built.

## Continuous Integration

`.github/workflows/build.yml` builds and smoke-tests on every pull request. Publishing happens
only on a push to `master` (or a `workflow_dispatch` run against `master`); a dispatch run against
any other branch still builds and smoke-tests but publishes nothing. Publishing needs two
repository secrets, `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.

There is no scheduled rebuild. A Teleport patch release or an Ubuntu base-image security fix
reaches the published image only when someone bumps the pin or re-runs the workflow.

A separate `dockerhub-description` job, master-only, syncs the Docker Hub repository page from
`DOCKERHUB-OVERVIEW.md` in this repo on every publish. **Editing the overview in the Docker Hub web
UI is overwritten on the next push to `master`** — edit `DOCKERHUB-OVERVIEW.md` instead. That file
is deliberately not generated from this README and does not cross-check it: it addresses someone
who has landed on the image without ever seeing this repo.

## License

**This repo's own code** — `Containerfile`, `Makefile`, `test/smoke.sh`, and the documentation —
is licensed under **AGPL-3.0-only**. The `LICENSE` file holds that text.

**The `tsh` binary this image ships** is under the **Teleport Community Edition License**, an
Apache-2.0 derivative that is neither AGPL nor stock Apache-2.0 — do not conflate the two. SPDX has
no identifier for it, so the image carries:

```
org.opencontainers.image.licenses="LicenseRef-Teleport-Community-Edition"
```

Teleport's source is at [github.com/gravitational/teleport](https://github.com/gravitational/teleport).
A copy of the Community Edition licence travels inside every image at
`/usr/share/doc/teleport/LICENSE-community`.

Both licences must be complied with when using this image. The eligibility limit stated at the top
of this document is part of the Community Edition licence's terms, not a separate policy of this
repo.

## Planned

**Multi-arch builds.** The build maps `uname -m` to the right download, so it is correct on
whatever architecture builds it, but no multi-arch manifest is published — a build on `arm64`
produces an `arm64` image and a build on `amd64` produces an `amd64` image, with no single tag
that resolves to the right one automatically for a puller of a different architecture.
