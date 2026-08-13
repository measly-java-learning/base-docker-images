# Multi-arch engine-build image

**Date:** 2026-08-12
**Status:** Approved design, not yet implemented.
**Supersedes:** the per-platform image layout sketched in
`docs/notes/2026-08-11-ci-build-image-sharing.md`.

## Why this exists

The repository currently publishes two independently maintained Dockerfiles,
`dockerfiles/linux-x86_64.Dockerfile` and `dockerfiles/linux-aarch64.Dockerfile`, which are
identical except for three lines: the `FROM` arch, the Corretto RPM URL, and its SHA256.

That reproduces the exact problem the consolidation was meant to delete. The motivating note
argues for one shared image because "both engines build in a byte-identical environment
removes the drift risk between two hand-maintained Dockerfile pairs" — and then the
implementation ships a hand-maintained Dockerfile pair.

A second, unrelated defect compounds it: both matrix legs publish through
`docker/metadata-action`'s default tag rules, so both push `:main` and `:sha-<short>` to the
same image name. Whichever job finishes second wins and the other architecture's manifest is
orphaned. The published image is silently whichever arch lost the race.

Multi-arch publishing fixes both at once, and is cheaper than it first appeared because of a
registry fact the original note did not account for.

## The enabling discovery

The note lists the bases as `quay.io/pypa/manylinux_2_28_x86_64` and
`…_aarch64` — two separate repositories. pypa also publishes a **merged** repository at the
same tag:

```
quay.io/pypa/manylinux_2_28:2026.06.04-1
  digest sha256:102e1adde208e2d9550cc94aaf70c66f09e0f80979e95e7f626ca82781d37379
  is_manifest_list: true, 5 children:
    linux/amd64    sha256:d3f051574f040b4c1d23b18fd06741cd7288c6f537faa0a76b1c7edf048bfa62
    linux/386      sha256:719b7fbee8bc6540e71c016e362f294a6e5cb4303cbef81cfdde6b9703b5c69b
    linux/arm64    sha256:3ab937ec86ca568d546a98e2d2616be3282e3e42b8e18ca0c233dcf9fb6293e6
    linux/ppc64le  sha256:e68494f6937337b0ac5ee8c0d2ed48276bbb0ad83018b7962c3433ea4c206899
    linux/s390x    sha256:92368c43a7126337828f230095eeae101c8b259850d2294d971f9b8d213a4526
```

The `linux/amd64` and `linux/arm64` children are digest-identical to what the two per-arch
repositories resolve to at the same tag. Switching to the merged repository therefore changes
nothing about what is built — it only lets one `FROM` line serve both architectures.

## Goals

- One Dockerfile producing both architectures.
- One image, one index digest, consumed by both engine repos.
- Every published manifest permanently addressable, so registry housekeeping cannot break a
  pinned consumer.
- The remaining publish-pipeline defects from the 2026-08-12 review fixed in the same pass,
  since they touch the same files.

## Non-goals

- Migrating the consumer repositories. Bumping pins in `measly-java-learning/djl-iree-engine`
  and `corey-cole/djl-executorch-engine` and deleting their per-repo container CI is separate
  work in those repos.
- The `iree-runtime-dist` clang/lld image. It stays a distinct image; the reusable workflow
  introduced here is what it will eventually call.
- Reproducible-by-content image builds. Digests are per-run, not per-commit (see Failure
  modes).

## Decisions

### D1 — Arch knowledge lives in the Dockerfile, via `TARGETARCH`

Rejected: passing `BASE_IMAGE`, `CORRETTO_URL`, and `CORRETTO_SHA256` as build args from the
workflow matrix. That keeps the Dockerfile branch-free but moves the reproducibility-critical
pins into YAML, away from the thing they pin, and makes a bare `docker build .` fail or
misbuild unless a contributor hand-copies three arguments out of a workflow file. The note
explicitly values the local-DX property that a contributor's first run costs nothing; a
zero-argument `docker build .` that works on either an x86 or ARM laptop is that property.

One caveat on that claim: it holds **on BuildKit**. `TARGETARCH` is a BuildKit-provided build
arg, so on a machine where `docker build` falls back to the deprecated legacy builder — Docker
installed without the buildx plugin, as on `radxa-dragon-q6a.local` — the variable is empty and
the build fails on the `case`'s catch-all arm. That is the guard behaving correctly, but the
message names the symptom rather than the cause. Contributors on such a machine should build
through a buildx node rather than the local daemon.

Also rejected: two Dockerfiles over a shared base image. Adds a publish stage and a second
digest to track, and relocates the drift risk rather than removing it.

### D2 — Base pinned by tag *and* digest

```dockerfile
FROM quay.io/pypa/manylinux_2_28:2026.06.04-1@sha256:102e1adde208e2d9550cc94aaf70c66f09e0f80979e95e7f626ca82781d37379
```

Docker resolves by digest and ignores the tag. Quay tags are movable — the API exposes a
`reversion` flag — and a floating base tag rebuilding underneath a green tree is precisely the
incident that motivated PR #27. This applies to ourselves the rule we are about to impose on
consumers. The tag is retained because a bare digest is not machine-updatable (see D6) and
because it names the pin for a human reader.

### D3 — Reusable workflow, not a composite action

A composite action contributes steps to a single job. Multi-arch requires a merge job that
runs after all arch jobs complete, which is a job-level construct. The reuse boundary must
therefore be a workflow with `on: workflow_call`. `.github/actions/publish-dockerfile/` is
deleted; its responsibilities move into `build-multi-arch-image.yml`.

This also removes the `setup` job. The `inputs` context is available in `jobs.<id>.strategy`
for a called workflow, so the matrix can read `fromJSON(inputs.platforms)` directly. The
existing `PLATFORMS` env → job output → `fromJSON` indirection exists only to work around
`env` not being visible in `strategy`, and is unnecessary once the values arrive as inputs.

### D4 — Per-arch manifests are tagged, not pushed by digest

The canonical `docker/build-push-action` multi-arch pattern pushes each arch with
`push-by-digest=true` — no tags, ever — and passes digests between jobs as artifacts. Only the
final index is tagged.

That leaves every architecture manifest permanently untagged. A GHCR "delete untagged
versions" retention rule would then delete the children out from under a live index, breaking
consumers who are pinned *right now*, not merely old ones. This is open question 4 in the
motivating note, and the answer under the canonical pattern is "you may never enable untagged
cleanup on this package."

Instead each arch job pushes to a deterministic immutable tag:

```
ghcr.io/<owner>/engine-build:sha-<short>-amd64
ghcr.io/<owner>/engine-build:sha-<short>-arm64
```

and the merge job builds the index from those tag references. Nothing load-bearing is ever
untagged, so retention policy becomes a non-question.

The side benefit is larger than the primary one: because both jobs derive the tag names
independently from `github.sha`, **no data passes between jobs at all**. No digest files, no
`upload-artifact`, no `download-artifact`.

The cost is permanent per-arch tags visible in the package listing, which are pullable and
could in principle be pinned by someone. The README states they are implementation detail.

### D5 — Tags are computed, not delegated to `metadata-action`

`docker/metadata-action` is retained for OCI labels only. Its default tag rules are what
produced the two-legs-one-tag collision, and deriving both the arch tags and the index tag
from a single `${GITHUB_SHA:0:7}` expression is what lets the merge job reconstruct the source
references without artifact passing.

Published tags:

| Tag | Mutability | Purpose |
| --- | --- | --- |
| `sha-<short>` | immutable, permanent | the index; what a consumer's digest was captured from |
| `main` | moves every build on main | browsing and ad-hoc local pulls only |
| `sha-<short>-<arch>` | immutable, permanent | index children; implementation detail |

`main` is applied only when `GITHUB_REF` is `refs/heads/main`, so a `workflow_dispatch` from a
branch publishes an immutable tag without moving the floating one.

The supported consumption interface is `ghcr.io/<owner>/engine-build@sha256:<index digest>`.
Tags are not a supported interface.

### D6 — No Dependabot for the base image; a tripwire instead

`quay.io/pypa/manylinux_2_28` publishes roughly two to three times a week. A Dependabot
`docker` ecosystem entry on a monthly schedule would open a PR every month, indefinitely, and
each would be either red or pointless:

- If the new base ships a different `gcc-toolset-14` release, `dnf install
  gcc-toolset-14-libasan-devel-14.2.1-11.el8_10` fails resolution, because the `-devel` package
  requires the matching `gcc-toolset-14-gcc` NEVRA. Red PR.
- If the new base ships the same gcc release, the PR is a new digest for a base that is
  materially identical for our purposes. Pointless PR.

This repository's purpose is to *not* move. Subscribing to a firehose of upstream rebuilds
fights that purpose. Base bumps are deliberate: a CVE, or a toolchain need.

In place of the Dependabot entry, the build asserts the invariant the comment block already
claims but nothing enforces — that the base's own `gcc-toolset-14-gcc` NEVRA equals
`MEASLY_DJL_TOOLSET_NEVRA`. A future manual bump then fails with `base ships gcc 14.2.1-12,
pins say 14.2.1-11` rather than an opaque dnf resolution error.

Dependabot continues to cover `github-actions`. The separate directory entry the review called
for is unnecessary once the composite action is deleted, since the remaining action references
all live in `.github/workflows/`.

### D7 — Attestation stays out of the registry

`actions/attest-build-provenance` runs once, in the merge job, against the index digest, with
`push-to-registry: false`. Attestations live in GitHub's attestation store and are verified
with:

```
gh attestation verify oci://ghcr.io/<owner>/engine-build@sha256:<digest> --owner <owner>
```

`push-to-registry: true` would instead store the attestation as an OCI referrer in GHCR. It is
not established whether GHCR surfaces referrer manifests as untagged package versions; if it
does, that reintroduces the retention hazard D4 removes. Keeping attestations in GitHub's store
sidesteps the question. Both the referrer behaviour and the `gh attestation verify` invocation
above are to be confirmed on first publish rather than assumed (see Open items).

### D8 — Pull requests build both architectures and push nothing

The Dockerfile's assertion block is the test suite, and it runs as part of the build. A PR run
therefore validates fully without any registry write, works from forks where `GITHUB_TOKEN` is
read-only, and accumulates no PR-tagged debris. The merge job is skipped on PRs — there is
nothing to merge.

## Design

### Dockerfile — `dockerfiles/engine-build.Dockerfile`

Replaces both existing files. Everything not listed below is carried over verbatim, including
the full comment block, the `MEASLY_DJL_*` environment variables, the pip ninja install and
`/usr/local/bin` symlink, and the `rpm2archive` find-then-symlink indirection. The
`MEASLY_DJL_*` names are a consumer-facing contract read by `native/build_qa.sh` and
`native/build.sh` in the engine repos and must not change in this work.

Three changes:

1. **Base** per D2 — the merged repository, tag plus digest.

2. **Corretto selected from `TARGETARCH`:**

   ```dockerfile
   ARG TARGETARCH
   ARG CORRETTO_VERSION=8.502.07.1
   ARG CORRETTO_RPM_VERSION=1.8.0_502.b07-1
   ARG CORRETTO_SHA256_amd64=8663ad535a10f8418ce6c3b97108e2dbbe49aef7c317eaef9f08f1d25d5a7286
   ARG CORRETTO_SHA256_arm64=ce812e8ab602fd999d2576ee4ae0eb82116017c7304dfb91601b5e312a6fc48c

   RUN set -eu; \
       case "${TARGETARCH}" in \
         amd64) rpm_arch=x86_64;  sha="${CORRETTO_SHA256_amd64}" ;; \
         arm64) rpm_arch=aarch64; sha="${CORRETTO_SHA256_arm64}" ;; \
         *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
       esac; \
       url="https://corretto.aws/downloads/resources/${CORRETTO_VERSION}/java-1.8.0-amazon-corretto-devel-${CORRETTO_RPM_VERSION}.${rpm_arch}.rpm"; \
       echo "fetching ${url}"; \
       # remainder unchanged: curl -fL, sha256sum -c against "${sha}", rpm2archive,
       # tar into /opt/corretto, find-then-symlink to /opt/corretto-jdk, rm the RPM
   ```

   `TARGETARCH` is populated by BuildKit and must be re-declared inside the stage to be
   visible. The `*)` arm is load-bearing: the base index also carries 386, ppc64le, and s390x
   children, so `--platform linux/s390x` would otherwise resolve a base successfully and then
   fetch a nonexistent RPM. The URL is echoed before the fetch so a 404 is diagnosable from the
   log.

3. **Assertion block converted to `set -eu` with `;` separators**, plus the D6 tripwire. The
   current `A && B || { echo "…"; exit 1; }` chain never swallows a failure — every branch ends
   in `exit 1` — but an early failure prints a later step's message; a `ninja --version` crash
   reports "libasan NEVRA not installed as pinned". Under `set -eu` each check aborts at its own
   line with its own message.

### Reusable workflow — `.github/workflows/build-multi-arch-image.yml`

```yaml
on:
  workflow_call:
    inputs:
      image-name:  { required: true, type: string }
      dockerfile:  { required: true, type: string }
      platforms:   { type: string, default: "<the JSON below>" }
      push:        { type: boolean, default: true }
    outputs:
      image:   # ghcr.io/<owner>/<image-name>, from the merge job
      digest:  # sha256:… of the index, from the merge job
```

Both outputs come from the `merge` job and are therefore empty on pull-request runs, where
that job does not execute. A future caller that chains on them must account for that.

Default `platforms`:

```json
[{"platform":"linux/amd64","arch":"amd64","runner":"ubuntu-latest"},
 {"platform":"linux/arm64","arch":"arm64","runner":"ubuntu-24.04-arm"}]
```

**`build` job** — `strategy.fail-fast: false`, `matrix.combo: ${{ fromJSON(inputs.platforms) }}`,
`runs-on: ${{ matrix.combo.runner }}`. Steps: checkout, `setup-buildx-action`,
`login-action` (skipped when not pushing), a `vars` step computing the image name and tag,
`metadata-action` for labels, then the build.

The `vars` step is identical in both jobs and is the single definition of the naming scheme:

```yaml
      - id: vars
        env:
          OWNER: ${{ github.repository_owner }}
          IMAGE_NAME: ${{ inputs.image-name }}
        run: |
          set -eu
          echo "image=ghcr.io/${OWNER,,}/${IMAGE_NAME}" >> "$GITHUB_OUTPUT"
          echo "sha_tag=sha-${GITHUB_SHA:0:7}"          >> "$GITHUB_OUTPUT"
```

```yaml
      - uses: docker/build-push-action@v7
        with:
          context: .
          file: ${{ inputs.dockerfile }}
          platforms: ${{ matrix.combo.platform }}
          push: ${{ inputs.push }}
          tags: ${{ steps.vars.outputs.image }}:${{ steps.vars.outputs.sha_tag }}-${{ matrix.combo.arch }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: false
          sbom: false
```

`provenance: false` matters: buildx otherwise attaches a provenance attestation, which turns
each arch tag into a small index rather than a plain manifest. Attestation belongs on the final
index, once. `${OWNER,,}` lowercases the owner — `measly-java-learning` already is, but GHCR
rejects uppercase path segments and this guards a future rename.

**`merge` job** — `if: inputs.push`, `needs: build`, `runs-on: ubuntu-latest`. Recomputes the
same `image` and `sha_tag`, then:

```bash
set -euo pipefail
# PLATFORMS is inputs.platforms, passed through the step env

mapfile -t srcs < <(jq -r --arg i "$IMAGE" --arg t "$SHA_TAG" \
                      '.[] | "\($i):\($t)-\(.arch)"' <<< "$PLATFORMS")

tags=(-t "$IMAGE:$SHA_TAG")
if [ "$GITHUB_REF" = refs/heads/main ]; then
  tags+=(-t "$IMAGE:main")
fi

docker buildx imagetools create "${tags[@]}" "${srcs[@]}"

digest=$(docker buildx imagetools inspect --format '{{json .Manifest.Digest}}' \
           "$IMAGE:$SHA_TAG" | tr -d '"')
```

Two details that are easy to get wrong and are called out for the implementer: the ref check
must be a full `if`, not `[ … ] && tags+=(…)`, because under `set -e` the `&&` form aborts the
step whenever the test is false — that is, on every `workflow_dispatch` run from a branch. And
both `srcs` and `tags` are arrays rather than word-split strings, so an image name containing
unexpected characters cannot restructure the command.

The source list is derived from the same `platforms` input the matrix consumed, so adding an
architecture is a one-line change in one place. The job then writes the pin line to
`$GITHUB_STEP_SUMMARY`, runs the index verification described below, and attests per D7.

### Caller — `.github/workflows/publish-engine-images.yml`

Reduced to triggers, concurrency, permissions, and one `uses:`.

- Triggers: `push` to `main` filtered on `dockerfiles/**`, `.github/workflows/**`,
  `.dockerignore`; `pull_request`; `workflow_dispatch`.
- `concurrency`: group on workflow and ref, `cancel-in-progress` only for pull requests. On
  main, two runs racing to `imagetools create -t …:main` could otherwise land in either order.
- `permissions`: `contents: read`, `packages: write`, `id-token: write`, `attestations: write`.
- `with`: `image-name: engine-build`, `dockerfile: dockerfiles/engine-build.Dockerfile`,
  `push: ${{ github.event_name != 'pull_request' }}`.

## Failure modes

**A broken image cannot be published.** The assertions are `RUN` steps inside the build, so a
missing `jni.h` or a drifted NEVRA fails the build. No path exists where a bad layer reaches
the registry and receives an index.

**Partial arch failure leaves debris, not corruption.** With `fail-fast: false` both legs
attempt, so both failures are reported. `needs: build` then blocks the merge, leaving one
orphaned `sha-<short>-<arch>` tag and no index. Nothing consumes arch tags and no index was
created, so a failed run is invisible to consumers; the next push republishes. Keeping both
diagnostics is worth the stray tag.

**Concurrent pushes to main queue rather than interleave**, per the concurrency setting above.

**An unsupported platform fails at the `case`**, before any network call, naming the arch.

**Index digests are per-run, not per-commit.** Layer timestamps and merge ordering are not
bit-reproducible, so rebuilding the same commit yields a different index digest. Consumers pin
the digest emitted by the specific run they intend to consume; it cannot be re-derived later by
rebuilding the same sha. This is stated explicitly in the README.

## Verification

1. **Every build, including pull requests** — the Dockerfile assertion block: `jni.h`,
   `jni_md.h`, `ninja` on `PATH`, the exact `ninja --version` string, both toolset NEVRAs via
   `rpm -q`, `sys/sdt.h`, and the D6 base-gcc tripwire.
2. **Every publish** — a merge-job step runs `docker buildx imagetools inspect "$IMAGE@$digest"`
   and asserts the platform set equals the requested platforms, catching a malformed or
   single-arch index before anyone pins it.
3. **First publish, manual** — resolve the index digest under `--platform linux/amd64` and
   `--platform linux/arm64` and confirm each passes the same checks from outside the build;
   then, logged out of GHCR entirely, `docker pull ghcr.io/<owner>/engine-build@sha256:<digest>`
   to prove anonymous cross-org pull works. That last check settles open question 2 in the
   motivating note and de-risks the consolidation premise.

## Documentation changes

**README.md** — the image table collapses to one row, since there is now one image serving both
architectures; the duplicated `linux-x86_64` row goes away with it. Added: the pin contract
(`@sha256:` index digests are the supported interface, `:main` is browsing only, `sha-…-<arch>`
tags are implementation detail); the one-time bootstrap step of flipping the GHCR package to
public after the first publish; the digests-are-per-run caveat; and the toolchain-bump
procedure — publish, copy the digest from the run's step summary, bump the pin in both consumer
repos.

**`docs/notes/2026-08-11-ci-build-image-sharing.md`** — the motivating note moves out of the
repository root.

**`.dockerignore`** — new. The build context currently ships `.git`.

## Files changed

| Path | Action |
| --- | --- |
| `dockerfiles/engine-build.Dockerfile` | new — replaces the pair |
| `dockerfiles/linux-x86_64.Dockerfile` | deleted |
| `dockerfiles/linux-aarch64.Dockerfile` | deleted |
| `.dockerignore` | new |
| `.github/workflows/build-multi-arch-image.yml` | new |
| `.github/workflows/publish-engine-images.yml` | rewritten as a thin caller |
| `.github/actions/publish-dockerfile/action.yml` | deleted |
| `.github/dependabot.yml` | unchanged — `github-actions` only, per D6 |
| `README.md` | rewritten |
| `2026-08-11-ci-build-image-sharing.md` | moved to `docs/notes/` |

## Risks and open items

**The pinned NEVRAs will eventually stop being installable.** AlmaLinux 8's AppStream repository
carries only current builds. When `gcc-toolset-14` gets its next upstream release,
`14.2.1-11.el8_10` disappears and the image stops building on unchanged source and an unchanged
base — the PR #27 incident arriving through the RPM repository instead of the base tag. This is
pre-existing and not introduced here.

Checked 2026-08-12 against the pinned base: all three NEVRAs still resolve from AppStream
(`gcc-toolset-14-libasan-devel-14.2.1-11.el8_10`,
`gcc-toolset-14-libubsan-devel-14.2.1-11.el8_10`, `systemtap-sdt-devel-4.9-3.el8`), so the risk
is latent rather than active. Mitigation when it bites is a vault or archive repository, or an
accepted re-pin. The D6 tripwire was verified against the same base: `rpm -q --qf
'%{VERSION}-%{RELEASE}' gcc-toolset-14-gcc` returns `14.2.1-11.el8_10`, matching
`MEASLY_DJL_TOOLSET_NEVRA` exactly.

**Attestation mechanics are confirmed** (D7): on first publish (2026-08-13), with
`push-to-registry: false`, `gh attestation verify oci://ghcr.io/measly-java-learning/
engine-build@sha256:725884538caa4f7f8444847e34b3928bb90089da95d5b77ce560aa2e624f905b
--owner measly-java-learning` exited 0 (the command's success is silent; the exit code is the
verdict). The attestation is discoverable from GitHub's attestation store without any registry
referrer, and GHCR's package listing shows 0 untagged versions — the D4 retention hazard does
not materialise, so `push-to-registry` stays `false`.

**GHCR package visibility is a confirmed one-time bootstrap.** The package was created private
by the first workflow publish, flipped to public once in package settings (2026-08-13), and
held: the package page shows Public, and `docker pull` of the index digest from a
logged-out shell (`docker logout ghcr.io` first) succeeded anonymously. The flip did not need
re-applying on this first publish; it is recorded in the README as a one-time bootstrap step.

**Action major versions are current** — the rewrite adopted `checkout@v7`,
`login-action@v4`, `metadata-action@v6`, `build-push-action@v7`, `setup-buildx-action@v3`, and
`attest-build-provenance@v3` directly (resolving the stale `v2`/`v5`/`v5` tree), and the first
publish run executed them successfully. Dependabot covers `github-actions` for future bumps.

## Related

- `docs/notes/2026-08-11-ci-build-image-sharing.md` — measurements and the consolidation argument
- PR #27 (pinned images), PR #28 (Catch2 gate)
- `corey-cole/djl-executorch-engine#38` (GHA cache scope collision, deleted along with the cache)
