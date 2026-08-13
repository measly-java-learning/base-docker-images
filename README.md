# base-docker-images

Utility repository for common CI/CD OCI images. Images build and publish automatically
through GitHub Actions.

## Available images

| Image | Description | Source |
| --- | --- | --- |
| `ghcr.io/measly-java-learning/engine-build` | Portable Linux release builder for engine builds. Multi-arch: `linux/amd64` and `linux/arm64`. | [Dockerfile](./dockerfiles/engine-build.Dockerfile) |

## Consuming an image

**Pin by digest. Digests are the only supported interface.**

```bash
docker run --rm ghcr.io/measly-java-learning/engine-build@sha256:<index digest> ...
```

The digest is a manifest list, so Docker selects the matching architecture automatically —
consumers do not pick a platform-specific reference.

Published tags and what they mean:

| Tag | Mutability | Use |
| --- | --- | --- |
| `sha-<short>` | immutable, permanent | the manifest list; where a pinned digest came from |
| `main` | **moves on every build** | browsing and ad-hoc local pulls only |
| `sha-<short>-<arch>` | immutable, permanent | manifest list children; implementation detail |

Pinning `:main` reintroduces exactly the failure this repository exists to prevent — a floating
tag rebuilding the toolchain underneath a green tree. Do not do it.

### Digests are per-run, not per-commit

Layer timestamps and merge ordering are not bit-reproducible, so rebuilding the same commit
produces a *different* index digest. Capture the digest emitted by the run you intend to
consume; it cannot be re-derived later by rebuilding the same sha.

## Bumping a consumer to a new image

1. Land the change here. The `Publish Engine Images` run prints the new pin in its job summary.
2. Copy the `…@sha256:…` line from that summary.
3. Bump the pin in each consumer repository.

Consumers today are `measly-java-learning/djl-iree-engine` and
`corey-cole/djl-executorch-engine`.

## Verifying provenance

Every published manifest list is attested. Attestations live in GitHub's attestation store,
not in the registry:

```bash
gh attestation verify \
  oci://ghcr.io/measly-java-learning/engine-build@sha256:<index digest> \
  --owner measly-java-learning
```

## Maintaining the pins

Everything is pinned deliberately: the base image by digest, the RPMs by exact NEVRA, Corretto
by versioned URL and SHA256, ninja by pip version. Dependabot covers GitHub Actions only — it
is deliberately **not** pointed at the base image, which publishes two to three times a week
and whose bumps require re-pinning the toolchain NEVRAs in lockstep. Bump the base when there
is a reason to: a CVE, or a toolchain need.

The build asserts that the base image's own `gcc-toolset-14-gcc` NEVRA matches
`MEASLY_DJL_TOOLSET_NEVRA`, so a base bump that moves the compiler fails with a precise message
rather than an opaque dnf resolution error.

## Repository bootstrap

One-time, after the very first successful publish: the GHCR package is created **private**.
`corey-cole/djl-executorch-engine` is in a different organization and pulls anonymously, so the
package must be switched to public in its package settings.

Do **not** enable a "delete untagged versions" retention rule without checking what it would
remove. Every manifest this repository publishes carries a permanent tag by design, precisely
so retention policy stays a non-question.

## Design documents

- [Multi-arch engine-build image design](./docs/superpowers/specs/2026-08-12-multi-arch-engine-build-design.md)
- [CI build-time analysis and the shared-image question](./docs/notes/2026-08-11-ci-build-image-sharing.md)
