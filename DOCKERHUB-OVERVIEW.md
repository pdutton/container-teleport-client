# pdutton/teleport-client

Teleport Community Edition's `tsh` client, ready to run without installing it — log in to a
Teleport cluster and `ssh` through it from a container.

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

## Usage

```bash
mkdir -p ~/.tsh   # podman does not create a bind mount's source directory for you
alias tsh='podman run -ti --rm -v "$HOME/.tsh":/root/.tsh docker.io/pdutton/teleport-client:latest tsh'

tsh login --proxy=teleport.example.com claude
tsh ssh claude@teleport-node
```

`-v "$HOME/.tsh":/root/.tsh` shares your host's Teleport identity with the container — log in once
from either side and both can use the session. `podman run -ti` is required: `tsh login` needs a
real terminal for the password and MFA prompts and will not accept a pipe.

The `mkdir -p ~/.tsh` matters on a brand-new host: podman's rootless bind mounts do not create the
source directory for you, so without it the very first login fails with
`statfs ...: no such file or directory`. Harmless to repeat if `~/.tsh` already exists.

## Tunnelling a Port

```bash
podman run -ti --rm --network=host -v "$HOME/.tsh":/root/.tsh \
  docker.io/pdutton/teleport-client:latest \
  tsh ssh -N -L 5901:localhost:5901 claude@teleport-node
```

`-N` holds the forward open without starting a remote shell. With `--network=host`, `tsh`'s
default `127.0.0.1` bind is the host loopback, so a viewer on the host connects to
`localhost:5901` directly. See the [repo README](https://github.com/pdutton/container-teleport-client)
for the isolated-network alternative.

## Tags

| Tag | Resolves to |
|---|---|
| `latest` | the current build |
| `18` | the newest build on the Teleport 18 line published here |
| `18.10` | the newest build on the Teleport 18.10 line published here |
| `18.10.4` | this exact version |

## Integrity, Not Authenticity

The build pins a per-architecture SHA-256 digest for the `tsh` tarball it downloads, which stops a
tarball silently republished under the same version name — but Teleport publishes no detached
signature for these tarballs, so this is integrity against tampering after the pin was taken, not
proof that Teleport authored the bytes. See the [repo README](https://github.com/pdutton/container-teleport-client#integrity-not-authenticity)
for the full explanation.

## Source

[github.com/pdutton/container-teleport-client](https://github.com/pdutton/container-teleport-client)

## Intended Audience

This image is for anyone the Teleport Community Edition License actually covers: individuals for
any purpose, and organizations under both the employee and revenue thresholds above — not just
personal use or learning. If you create useful container images based on this one, please share
the code you used to produce them so everyone can benefit.

This repo's own code is licensed under AGPL-3.0-only, but **the Teleport binary this image ships
is not open source** — it carries its own licence with the eligibility limit above. You must comply
with *both* licences when using and extending this image.
