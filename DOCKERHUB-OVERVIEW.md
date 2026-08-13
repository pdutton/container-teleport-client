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

## Usage

```bash
alias tsh='podman run -ti --rm -v "$HOME/.tsh":/root/.tsh docker.io/pdutton/teleport-client:latest tsh'

tsh login --proxy=teleport.example.com claude
tsh ssh claude@teleport-node
```

`-v "$HOME/.tsh":/root/.tsh` shares your host's Teleport identity with the container — log in once
from either side and both can use the session. `podman run -ti` is required: `tsh login` needs a
real terminal for the password and MFA prompts and will not accept a pipe.

If `~/.tsh` doesn't exist yet (first run), create it first — `mkdir -p ~/.tsh` — podman does not
create a bind mount's source directory for you.

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

## Source

[github.com/pdutton/container-teleport-client](https://github.com/pdutton/container-teleport-client)

## Intended Audience

Feel free to use this container image for personal use or learning. If you create useful
container images based on this one, please share the code you used to produce them so everyone can
benefit.

This repo's own code is licensed under AGPL-3.0-only, but **the Teleport binary this image ships
is not open source** — it carries its own licence with the eligibility limit above. You must comply
with *both* licences when using and extending this image.
