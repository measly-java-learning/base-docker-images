# Multi-arch engine-build image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two per-architecture engine build Dockerfiles with a single
`TARGETARCH`-driven Dockerfile published as one multi-arch manifest list, and fix the publish
pipeline defects that currently make both matrix legs overwrite each other's tag.

**Architecture:** One Dockerfile builds from the *merged* `manylinux_2_28` manifest list, so
BuildKit picks the arch child automatically; the only arch-dependent asset is the Corretto JDK
RPM, chosen by a `case` on `TARGETARCH`. A reusable workflow (`workflow_call`) builds each
architecture natively on its own runner and pushes to an immutable per-arch tag, then a merge
job stitches those tags into a manifest list with `docker buildx imagetools create`. Consumers
pin the resulting index digest.

**Tech Stack:** Docker BuildKit / buildx, GitHub Actions reusable workflows,
`docker/build-push-action@v7`, `docker/metadata-action@v6`, `docker/login-action@v4`,
`actions/attest-build-provenance@v3`, GHCR, `jq`, bash.

**Spec:** `docs/superpowers/specs/2026-08-12-multi-arch-engine-build-design.md`. Decision
references below (D1–D8) point at that document.

## Global Constraints

Every task's requirements implicitly include this section. Values are verbatim and must not be
retyped from memory.

- **Base image (D2):** `quay.io/pypa/manylinux_2_28:2026.06.04-1@sha256:102e1adde208e2d9550cc94aaf70c66f09e0f80979e95e7f626ca82781d37379`
- **RPM pins:** `gcc-toolset-14-libasan-devel-14.2.1-11.el8_10`,
  `gcc-toolset-14-libubsan-devel-14.2.1-11.el8_10`, `systemtap-sdt-devel-4.9-3.el8`
- **Corretto:** version `8.502.07.1`, RPM version `1.8.0_502.b07-1`
  - amd64 SHA256: `8663ad535a10f8418ce6c3b97108e2dbbe49aef7c317eaef9f08f1d25d5a7286`
  - arm64 SHA256: `ce812e8ab602fd999d2576ee4ae0eb82116017c7304dfb91601b5e312a6fc48c`
- **Ninja:** pip package `ninja==1.13.0`; reported version string
  `1.13.0.git.kitware.jobserver-pipe-1` (these differ — the assertion compares the *reported*
  string)
- **Consumer contract — do not rename or change values:** `MEASLY_DJL_PINNED_IMAGE=1`,
  `MEASLY_DJL_TOOLSET_VER=14`, `MEASLY_DJL_TOOLSET_NEVRA=14.2.1-11.el8_10`,
  `MEASLY_DJL_NINJA_VERSION=1.13.0.git.kitware.jobserver-pipe-1`, `JAVA_HOME=/opt/corretto-jdk`.
  These are read by `native/build.sh` and `native/build_qa.sh` in the engine repos.
- **Action majors (adopt current, per spec Risks):** checkout v7, login-action v4,
  metadata-action v6, build-push-action v7, setup-buildx-action v3, attest-build-provenance v3.
- **Tag scheme (D5):** index `sha-<short7>` always, `main` only on `refs/heads/main`; children
  `sha-<short7>-<arch>`. Supported consumption interface is the index digest only.
- **Dependabot (D6):** `github-actions` ecosystem only. Do **not** add a `docker` ecosystem entry.
- **Local tooling available:** `docker` 29.7.2, `buildx` v0.36.1, `actionlint` 1.7.12 (runs
  shellcheck over `run:` blocks), `shellcheck`, `jq` 1.7, `gh` 2.97.0. `hadolint` is **not**
  installed — do not add steps that require it. `qemu-aarch64` **is** registered, so
  `--platform linux/arm64` builds work locally.

---

### Task 1: Consolidate the two Dockerfiles into one multi-arch Dockerfile

**Files:**
- Create: `dockerfiles/engine-build.Dockerfile`
- Create: `.dockerignore`
- Delete: `dockerfiles/linux-x86_64.Dockerfile`
- Delete: `dockerfiles/linux-aarch64.Dockerfile`
- Test: the Dockerfile's own assertion `RUN` (there is no separate test file; the build *is*
  the test)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a Dockerfile at `dockerfiles/engine-build.Dockerfile` that builds with zero build
  args on `linux/amd64` and `linux/arm64`, and exports the environment variables listed under
  Global Constraints. Task 3 references this exact path as the `dockerfile` input.

- [ ] **Step 1: Create `.dockerignore`**

The build context currently ships `.git` and the docs tree to the daemon on every build.

```
.git
.github
docs
LICENSE
README.md
*.md
```

- [ ] **Step 2: Create `dockerfiles/engine-build.Dockerfile`**

This is the complete file. The comment blocks are carried over from the deleted pair
deliberately — they record *why* each pin exists and are the most valuable part of the file.

```dockerfile
# Consistent engine build image with build and QA tooling.
# Assets are pinned to exact NEVRAs; the base is pinned by digest.
#
# One Dockerfile serves both linux/amd64 and linux/arm64. The base is the *merged*
# manylinux_2_28 repository, which is a manifest list, so BuildKit resolves the correct
# per-arch child from the build platform automatically. The only arch-dependent asset is
# the Corretto JDK RPM, selected from TARGETARCH below.
#
# The tag on the FROM line is informational -- Docker resolves by digest and ignores it. It
# is kept because a bare digest is not machine-updatable and because it names the pin for a
# human reader. Quay tags are movable (the API exposes a `reversion` flag), so the digest is
# the real pin: a floating base tag rebuilding underneath a green tree is the incident that
# motivated pinning in the first place.
FROM quay.io/pypa/manylinux_2_28:2026.06.04-1@sha256:102e1adde208e2d9550cc94aaf70c66f09e0f80979e95e7f626ca82781d37379

# gcc-toolset-14-libasan-devel  the ASan runtime for native/build_qa.sh. Held to 14.2.1-11.el8_10
#                      to match the base image's own compiler exactly (gcc 14.2.1-11); a libasan
#                      from a different toolset revision than the gcc that emitted the
#                      instrumentation is the classic source of confusing ASan link errors.
#                      build_qa.sh asserts these NEVRAs via rpm -q against the image's pins and
#                      installs nothing; outside the image it probes that the host toolchain can
#                      link -fsanitize=address/undefined.
# gcc-toolset-14-libubsan-devel  the UBSan runtime for native/build_qa.sh and
#                      native/ubsan_gate.sh. Same NEVRA as libasan above and for the same
#                      reason: it must match the gcc that emitted the instrumentation.
# systemtap-sdt-devel  provides <sys/sdt.h>, required to build USDT tracepoints.
#                      Only the external bpftrace/perf tracepoints need this header. A missing
#                      header is an observability-only loss at runtime but a hard compile
#                      failure at build time.
RUN dnf install -y \
      gcc-toolset-14-libasan-devel-14.2.1-11.el8_10 \
      gcc-toolset-14-libubsan-devel-14.2.1-11.el8_10 \
      systemtap-sdt-devel-4.9-3.el8 \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# The consumer scripts assert against these rather than installing anything: presence of
# MEASLY_DJL_PINNED_IMAGE means "you are in the pinned image, a missing tool is a broken image,
# not something to fix at run time". Keep the NEVRA here identical to the dnf line above --
# this is the single source of truth, and native/build_qa.sh reads it from the environment.
ENV MEASLY_DJL_PINNED_IMAGE=1
ENV MEASLY_DJL_TOOLSET_VER=14
ENV MEASLY_DJL_TOOLSET_NEVRA=14.2.1-11.el8_10
# MEASLY_DJL_NINJA_VERSION is the version string the pip ninja wheel's binary reports
# (`ninja --version`), NOT the pip package metadata version: pip installs ninja==1.13.0 (pin
# unchanged), but the Kitware jobserver-pipe wheel prints
# "1.13.0.git.kitware.jobserver-pipe-1". Both this image's assertion below and
# native/build.sh compare exactly against `ninja --version` output, so this must be the
# reported string, not the metadata version.
ENV MEASLY_DJL_NINJA_VERSION=1.13.0.git.kitware.jobserver-pipe-1

# The base ships no ninja, and native/build.sh configures with -G Ninja, so every build paid a
# `pip install ninja` before this. cp312 is the interpreter native/build.sh already puts on PATH.
# Symlinked into /usr/local/bin so `ninja` resolves however the container is entered, not only
# after build.sh's PATH line.
RUN /opt/python/cp312-cp312/bin/pip install --no-cache-dir ninja==1.13.0 \
    && ln -s /opt/python/cp312-cp312/bin/ninja /usr/local/bin/ninja

# JNI headers. We compile against jni.h and never link libjvm, so this is a headers-only need --
# but it used to cost a 113 MB RPM download on every single build, in CI and locally.
#
# VERSIONED urls only, never https://corretto.aws/downloads/latest/... -- that redirect is
# exactly what makes a layer non-reproducible. sha256 computed from the artifact; Corretto's
# latest_checksum endpoint serves MD5, so do not expect to find these published upstream.
# Corretto 8 (not a newer JDK) for the oldest supported jni.h and the widest runtime
# compatibility, matching what the Windows job binds via JAVA_HOME_8_X64.
#
# TARGETARCH is supplied by BuildKit and must be re-declared inside the stage to be visible.
ARG TARGETARCH
ARG CORRETTO_VERSION=8.502.07.1
ARG CORRETTO_RPM_VERSION=1.8.0_502.b07-1
ARG CORRETTO_SHA256_amd64=8663ad535a10f8418ce6c3b97108e2dbbe49aef7c317eaef9f08f1d25d5a7286
ARG CORRETTO_SHA256_arm64=ce812e8ab602fd999d2576ee4ae0eb82116017c7304dfb91601b5e312a6fc48c

# rpm2archive, not rpm2cpio: this image ships no cpio. The find-then-symlink indirection is
# deliberate -- hardcoding the current extraction path
# (/opt/corretto/usr/lib/jvm/java-1.8.0-amazon-corretto) means a Corretto directory rename
# yields an image with a dangling JAVA_HOME and no error until a shim build dies deep in a
# CMake configure. Everything is removed in the same layer so the RPM is not carried in the
# image.
#
# The catch-all case arm is load-bearing: the base manifest list also carries 386, ppc64le and
# s390x children, so an unsupported --platform would otherwise resolve a base successfully and
# then fetch a nonexistent RPM.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) rpm_arch=x86_64;  sha="${CORRETTO_SHA256_amd64}" ;; \
      arm64) rpm_arch=aarch64; sha="${CORRETTO_SHA256_arm64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://corretto.aws/downloads/resources/${CORRETTO_VERSION}/java-1.8.0-amazon-corretto-devel-${CORRETTO_RPM_VERSION}.${rpm_arch}.rpm"; \
    echo "fetching ${url}"; \
    curl -fL -o /tmp/corretto.rpm "${url}"; \
    echo "${sha}  /tmp/corretto.rpm" | sha256sum -c -; \
    rpm2archive /tmp/corretto.rpm; \
    mkdir -p /opt/corretto; \
    tar -C /opt/corretto -xzf /tmp/corretto.rpm.tgz; \
    jni_h="$(find /opt/corretto -path '*/include/jni.h' | head -1)"; \
    if [ -z "${jni_h}" ]; then \
      echo "no include/jni.h found in the extracted Corretto RPM" >&2; exit 1; \
    fi; \
    ln -s "${jni_h%/include/jni.h}" /opt/corretto-jdk; \
    rm -f /tmp/corretto.rpm /tmp/corretto.rpm.tgz

ENV JAVA_HOME=/opt/corretto-jdk

# Fail at image-build time, not three steps into a shim build, if a pin ever stops delivering
# what it is here for. `set -eu` with one check per line means each failure reports its own
# message; the previous && / || chain reported a later step's message for an earlier failure.
RUN set -eu; \
    if [ ! -f "${JAVA_HOME}/include/jni.h" ]; then \
      echo "JAVA_HOME=${JAVA_HOME} has no include/jni.h" >&2; exit 1; \
    fi; \
    if [ ! -f "${JAVA_HOME}/include/linux/jni_md.h" ]; then \
      echo "JAVA_HOME=${JAVA_HOME} has no include/linux/jni_md.h" >&2; exit 1; \
    fi; \
    if ! command -v ninja >/dev/null; then \
      echo "ninja is not on PATH" >&2; exit 1; \
    fi; \
    ninja_ver="$(ninja --version)"; \
    if [ "${ninja_ver}" != "${MEASLY_DJL_NINJA_VERSION}" ]; then \
      echo "ninja is ${ninja_ver}, expected ${MEASLY_DJL_NINJA_VERSION}" >&2; exit 1; \
    fi; \
    if ! rpm -q "gcc-toolset-${MEASLY_DJL_TOOLSET_VER}-libasan-devel-${MEASLY_DJL_TOOLSET_NEVRA}" >/dev/null; then \
      echo "libasan NEVRA not installed as pinned" >&2; exit 1; \
    fi; \
    if ! rpm -q "gcc-toolset-${MEASLY_DJL_TOOLSET_VER}-libubsan-devel-${MEASLY_DJL_TOOLSET_NEVRA}" >/dev/null; then \
      echo "libubsan NEVRA not installed as pinned" >&2; exit 1; \
    fi; \
    base_gcc="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "gcc-toolset-${MEASLY_DJL_TOOLSET_VER}-gcc")"; \
    if [ "${base_gcc}" != "${MEASLY_DJL_TOOLSET_NEVRA}" ]; then \
      echo "base ships gcc ${base_gcc}, pins say ${MEASLY_DJL_TOOLSET_NEVRA}; update the NEVRA pins" >&2; \
      exit 1; \
    fi; \
    if [ ! -e /usr/include/sys/sdt.h ]; then \
      echo "systemtap-sdt-devel installed but /usr/include/sys/sdt.h is missing" >&2; exit 1; \
    fi; \
    echo "image assertions passed for TARGETARCH=${TARGETARCH}"
```

The `base_gcc` check is the D6 tripwire. It has been verified against the pinned base: `rpm -q
--qf '%{VERSION}-%{RELEASE}' gcc-toolset-14-gcc` returns `14.2.1-11.el8_10`.

- [ ] **Step 3: Build natively for amd64 and confirm the assertions pass**

```bash
docker buildx build --platform linux/amd64 -f dockerfiles/engine-build.Dockerfile -t engine-build:test-amd64 --load .
```

Expected: build succeeds, and the final layer prints
`image assertions passed for TARGETARCH=amd64`.

- [ ] **Step 4: Red-test the tripwire**

Prove the new assertion actually fires rather than being decorative. Temporarily edit only the
`ENV MEASLY_DJL_TOOLSET_NEVRA` line to a value the base cannot match:

```bash
sed -i 's/^ENV MEASLY_DJL_TOOLSET_NEVRA=.*/ENV MEASLY_DJL_TOOLSET_NEVRA=14.2.1-99.el8_10/' \
  dockerfiles/engine-build.Dockerfile
docker buildx build --platform linux/amd64 -f dockerfiles/engine-build.Dockerfile -t engine-build:redtest .
```

Expected: FAIL. Because the dnf line still uses the literal pin, the `rpm -q` libasan check
fires first with `libasan NEVRA not installed as pinned`. That is correct behaviour and proves
the assertion chain aborts at the first failure with its own message rather than a later one.

- [ ] **Step 5: Revert the tripwire edit and confirm green again**

```bash
sed -i 's/^ENV MEASLY_DJL_TOOLSET_NEVRA=.*/ENV MEASLY_DJL_TOOLSET_NEVRA=14.2.1-11.el8_10/' \
  dockerfiles/engine-build.Dockerfile
git diff --exit-code dockerfiles/engine-build.Dockerfile 2>/dev/null || true
docker buildx build --platform linux/amd64 -f dockerfiles/engine-build.Dockerfile -t engine-build:test-amd64 --load .
```

Expected: PASS, printing `image assertions passed for TARGETARCH=amd64`. Confirm by eye that
the `ENV MEASLY_DJL_TOOLSET_NEVRA` line reads `14.2.1-11.el8_10` before continuing.

- [ ] **Step 6: Build for arm64 under emulation**

`qemu-aarch64` is registered on this machine, so this is a real cross-arch build. It is
substantially slower than the native build — the `dnf` and `pip` layers run emulated. Allow up
to ~30 minutes.

```bash
docker buildx build --platform linux/arm64 -f dockerfiles/engine-build.Dockerfile -t engine-build:test-arm64 .
```

Expected: build succeeds, printing `image assertions passed for TARGETARCH=arm64`. This is the
one local check that the arm64 Corretto SHA256 is correct — CI would otherwise be the first
place that pin is exercised.

- [ ] **Step 7: Spot-check the built image matches the consumer contract**

```bash
docker run --rm engine-build:test-amd64 bash -c '
  set -eu
  echo "JAVA_HOME=$JAVA_HOME"
  test -f "$JAVA_HOME/include/jni.h"
  ninja --version
  echo "$MEASLY_DJL_PINNED_IMAGE $MEASLY_DJL_TOOLSET_VER $MEASLY_DJL_TOOLSET_NEVRA"
  rpm -q gcc-toolset-14-libasan-devel-14.2.1-11.el8_10
  test -e /usr/include/sys/sdt.h
  echo OK'
```

Expected: prints `JAVA_HOME=/opt/corretto-jdk`, `1.13.0.git.kitware.jobserver-pipe-1`,
`1 14 14.2.1-11.el8_10`, the libasan NEVRA, and `OK`.

- [ ] **Step 8: Delete the superseded Dockerfiles**

```bash
git rm dockerfiles/linux-x86_64.Dockerfile dockerfiles/linux-aarch64.Dockerfile
```

Note: these files are currently untracked in git. If `git rm` reports `did not match any
files`, remove them with plain `rm` instead.

- [ ] **Step 9: Commit**

```bash
git add .dockerignore dockerfiles/
git commit -m "feat: single multi-arch engine-build Dockerfile

Replaces the near-identical per-arch pair with one TARGETARCH-driven
Dockerfile over the merged manylinux_2_28 manifest list, pinned by digest.
Adds a tripwire asserting the base's own gcc NEVRA matches the pins, and
converts the assertion block to set -eu so each check reports its own
message."
```

---

### Task 2: Add the reusable multi-arch build workflow

**Files:**
- Create: `.github/workflows/build-multi-arch-image.yml`
- Test: `actionlint` (which also runs shellcheck over every `run:` block)

**Interfaces:**
- Consumes: `dockerfiles/engine-build.Dockerfile` from Task 1, via the `dockerfile` input.
- Produces: a workflow callable as
  `uses: ./.github/workflows/build-multi-arch-image.yml` with inputs `image-name` (string,
  required), `dockerfile` (string, required), `platforms` (string, JSON array, optional), and
  `push` (boolean, optional, default `true`); and outputs `image` (string) and `digest`
  (string), both empty on runs where `push` is false. Task 3 calls exactly this.

- [ ] **Step 1: Create `.github/workflows/build-multi-arch-image.yml`**

```yaml
name: Build multi-arch image

on:
  workflow_call:
    inputs:
      image-name:
        description: Image name under the owner namespace, e.g. engine-build
        required: true
        type: string
      dockerfile:
        description: Path to the Dockerfile, relative to the repository root
        required: true
        type: string
      platforms:
        description: JSON array of {platform, arch, runner} objects
        required: false
        type: string
        default: >-
          [
            {"platform":"linux/amd64","arch":"amd64","runner":"ubuntu-latest"},
            {"platform":"linux/arm64","arch":"arm64","runner":"ubuntu-24.04-arm"}
          ]
      push:
        description: Push and merge. False for pull requests, which build only.
        required: false
        type: boolean
        default: true
    outputs:
      image:
        description: Fully qualified image name. Empty when push is false.
        value: ${{ jobs.merge.outputs.image }}
      digest:
        description: Digest of the published manifest list. Empty when push is false.
        value: ${{ jobs.merge.outputs.digest }}

jobs:
  build:
    runs-on: ${{ matrix.combo.runner }}
    strategy:
      fail-fast: false
      matrix:
        combo: ${{ fromJSON(inputs.platforms) }}
    steps:
      - uses: actions/checkout@v7

      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        if: ${{ inputs.push }}
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}

      # Duplicated verbatim in the merge job on purpose. Matrix job outputs are
      # last-writer-wins across legs, so recomputing is clearer than plumbing an
      # output through a fan-in.
      - name: Compute image name and tag
        id: vars
        env:
          OWNER: ${{ github.repository_owner }}
          IMAGE_NAME: ${{ inputs.image-name }}
        run: |
          set -euo pipefail
          echo "image=ghcr.io/${OWNER,,}/${IMAGE_NAME}" >> "$GITHUB_OUTPUT"
          echo "sha_tag=sha-${GITHUB_SHA:0:7}" >> "$GITHUB_OUTPUT"

      - name: Extract OCI labels
        id: meta
        uses: docker/metadata-action@v6
        with:
          images: ${{ steps.vars.outputs.image }}

      # provenance/sbom are disabled here so each arch tag stays a plain manifest.
      # Buildx would otherwise wrap it in a small index, and attestation belongs on
      # the final manifest list, once, in the merge job.
      - name: Build and push
        uses: docker/build-push-action@v7
        with:
          context: .
          file: ${{ inputs.dockerfile }}
          platforms: ${{ matrix.combo.platform }}
          push: ${{ inputs.push }}
          tags: ${{ steps.vars.outputs.image }}:${{ steps.vars.outputs.sha_tag }}-${{ matrix.combo.arch }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: false
          sbom: false

  merge:
    if: ${{ inputs.push }}
    needs: build
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.vars.outputs.image }}
      digest: ${{ steps.index.outputs.digest }}
    steps:
      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}

      - name: Compute image name and tag
        id: vars
        env:
          OWNER: ${{ github.repository_owner }}
          IMAGE_NAME: ${{ inputs.image-name }}
        run: |
          set -euo pipefail
          echo "image=ghcr.io/${OWNER,,}/${IMAGE_NAME}" >> "$GITHUB_OUTPUT"
          echo "sha_tag=sha-${GITHUB_SHA:0:7}" >> "$GITHUB_OUTPUT"

      - name: Create manifest list
        id: index
        env:
          IMAGE: ${{ steps.vars.outputs.image }}
          SHA_TAG: ${{ steps.vars.outputs.sha_tag }}
          PLATFORMS: ${{ inputs.platforms }}
        run: |
          set -euo pipefail
          mapfile -t srcs < <(jq -r --arg i "$IMAGE" --arg t "$SHA_TAG" \
                                '.[] | "\($i):\($t)-\(.arch)"' <<< "$PLATFORMS")
          tags=(-t "$IMAGE:$SHA_TAG")
          # Must be a full `if`. Under `set -e`, `[ ... ] && tags+=(...)` aborts the
          # step whenever the test is false, i.e. on every dispatch from a branch.
          if [ "$GITHUB_REF" = refs/heads/main ]; then
            tags+=(-t "$IMAGE:main")
          fi
          docker buildx imagetools create "${tags[@]}" "${srcs[@]}"
          digest=$(docker buildx imagetools inspect \
                     --format '{{json .Manifest.Digest}}' "$IMAGE:$SHA_TAG" | tr -d '"')
          echo "digest=$digest" >> "$GITHUB_OUTPUT"

      - name: Verify the index resolves every requested platform
        env:
          IMAGE: ${{ steps.vars.outputs.image }}
          DIGEST: ${{ steps.index.outputs.digest }}
          PLATFORMS: ${{ inputs.platforms }}
        run: |
          set -euo pipefail
          got=$(docker buildx imagetools inspect --raw "$IMAGE@$DIGEST" \
                | jq -r '[.manifests[]
                          | select(.platform.os != "unknown")
                          | "\(.platform.os)/\(.platform.architecture)"]
                         | sort | join(",")')
          want=$(jq -r '[.[].platform] | sort | join(",")' <<< "$PLATFORMS")
          echo "index advertises: $got"
          echo "expected:         $want"
          if [ "$got" != "$want" ]; then
            echo "manifest list does not match the requested platforms" >&2
            exit 1
          fi

      - name: Write the pin to the job summary
        env:
          IMAGE: ${{ steps.vars.outputs.image }}
          DIGEST: ${{ steps.index.outputs.digest }}
        run: |
          set -euo pipefail
          # Four-space indent renders as a code block. Deliberately avoids fenced
          # blocks so this script contains no backticks of its own.
          {
            echo "### Published"
            echo
            echo "    ${IMAGE}@${DIGEST}"
            echo
            echo "Pin consumers to the digest above. Tags are not a supported interface."
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Attest build provenance
        uses: actions/attest-build-provenance@v3
        with:
          subject-name: ${{ steps.vars.outputs.image }}
          subject-digest: ${{ steps.index.outputs.digest }}
          push-to-registry: false
```

- [ ] **Step 2: Lint the workflow**

```bash
actionlint .github/workflows/build-multi-arch-image.yml
```

Expected: no output (clean). `actionlint` shells out to `shellcheck` for each `run:` block, so
this also covers the bash. If shellcheck flags SC2086 on an intentional expansion, prefer
fixing the quoting over adding a disable comment — every expansion in this file is already
array-based or quoted.

- [ ] **Step 3: Confirm the YAML parses and the expected structure exists**

```bash
python3 -c "
import yaml, sys
d = yaml.safe_load(open('.github/workflows/build-multi-arch-image.yml'))
call = d[True]['workflow_call'] if True in d else d['on']['workflow_call']
assert set(call['inputs']) == {'image-name','dockerfile','platforms','push'}, call['inputs']
assert set(call['outputs']) == {'image','digest'}, call['outputs']
assert set(d['jobs']) == {'build','merge'}, d['jobs']
assert d['jobs']['merge']['needs'] == 'build'
print('structure ok')
"
```

Expected: `structure ok`. (The `d[True]` dance is because PyYAML parses the bare key `on` as
the boolean `True`.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-multi-arch-image.yml
git commit -m "feat: reusable multi-arch image build workflow

Builds each architecture natively on its own runner, pushes to an
immutable per-arch tag, then merges those tags into a manifest list.
Per-arch children stay permanently tagged so registry retention cannot
break a digest-pinned consumer, which also removes the need to pass
digests between jobs as artifacts."
```

---

### Task 3: Rewrite the caller workflow and delete the composite action

**Files:**
- Modify: `.github/workflows/publish-engine-images.yml` (full rewrite)
- Delete: `.github/actions/publish-dockerfile/action.yml` (and the now-empty directory)
- Test: `actionlint`, plus a grep for dangling references

**Interfaces:**
- Consumes: `.github/workflows/build-multi-arch-image.yml` from Task 2, with inputs
  `image-name`, `dockerfile`, `push`; and `dockerfiles/engine-build.Dockerfile` from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Replace `.github/workflows/publish-engine-images.yml` entirely**

```yaml
name: Publish Engine Images

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths:
      - dockerfiles/**
      - .dockerignore
      - .github/workflows/publish-engine-images.yml
      - .github/workflows/build-multi-arch-image.yml
  pull_request:
    paths:
      - dockerfiles/**
      - .dockerignore
      - .github/workflows/publish-engine-images.yml
      - .github/workflows/build-multi-arch-image.yml

# Cancel superseded PR runs, but never cancel on main: two runs racing to
# `imagetools create -t ...:main` could otherwise land in either order.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  engine-build:
    uses: ./.github/workflows/build-multi-arch-image.yml
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    with:
      image-name: engine-build
      dockerfile: dockerfiles/engine-build.Dockerfile
      push: ${{ github.event_name != 'pull_request' }}
```

- [ ] **Step 2: Delete the composite action**

Its build-tag-push-in-one-job shape cannot express a merge job (spec D3), and every input it
declared is now handled by the reusable workflow.

```bash
git rm -r .github/actions/publish-dockerfile
rmdir .github/actions 2>/dev/null || true
```

If `git rm` reports `did not match any files` (the tree is currently untracked), use
`rm -rf .github/actions` instead.

- [ ] **Step 3: Verify no dangling references remain**

```bash
grep -rn "publish-dockerfile\|linux-x86_64.Dockerfile\|linux-aarch64.Dockerfile" \
  --exclude-dir=.git --exclude-dir=docs . || echo "no dangling references"
```

Expected: `no dangling references`. Matches inside `docs/` are expected and excluded — the spec
and note describe the old layout deliberately.

- [ ] **Step 4: Lint both workflows together**

```bash
actionlint
```

Expected: no output. Running bare picks up every workflow, which also catches a mismatch
between the caller's `with:` block and the reusable workflow's declared inputs.

- [ ] **Step 5: Commit**

```bash
git add -A .github
git commit -m "refactor: publish via the reusable multi-arch workflow

Reduces the caller to triggers, concurrency, permissions and one uses:.
Deletes the composite action, whose single-job shape could not express
the manifest merge, and whose metadata-action defaults were pushing both
matrix legs to the same tag."
```

---

### Task 4: Rewrite the README for the digest-pinning contract

**Files:**
- Modify: `README.md` (full rewrite)
- Verify unchanged: `.github/dependabot.yml`
- Test: grep assertions on the rendered content

**Interfaces:**
- Consumes: the tag scheme from Task 2 and the image name from Task 3.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Replace `README.md` entirely**

````markdown
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
````

- [ ] **Step 2: Assert the README no longer describes the old layout**

```bash
set -eu
! grep -q "linux-x86_64" README.md
! grep -q "linux-aarch64" README.md
grep -q "engine-build@sha256:" README.md
grep -q "Digests are per-run" README.md
echo "README assertions passed"
```

Expected: `README assertions passed`. The first two catch the duplicated-row bug from the
original table, which listed `linux-x86_64` twice.

- [ ] **Step 3: Confirm dependabot is unchanged per D6**

```bash
grep -c "package-ecosystem" .github/dependabot.yml
grep -q "docker" .github/dependabot.yml && echo "UNEXPECTED docker entry" || echo "github-actions only, as designed"
```

Expected: `1`, then `github-actions only, as designed`. This step exists because the earlier
review recommended adding a docker ecosystem entry and D6 reversed that; it guards against the
recommendation being re-applied from memory.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README for the digest-pinning contract

States the supported interface (index digests), the per-run digest
caveat, the consumer bump procedure, the public-package bootstrap, and
why Dependabot is deliberately not pointed at the base image."
```

---

### Task 5: First publish and close the spec's open items

This task is interactive and depends on GitHub, not on local tooling. It cannot be completed by
an agent working offline. Its purpose is to convert the spec's three Open Items into recorded
answers.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-multi-arch-engine-build-design.md` (Risks and open
  items section)

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: nothing.

- [ ] **Step 1: Push the branch and open a pull request**

```bash
git push -u origin HEAD
gh pr create --fill
```

- [ ] **Step 2: Confirm the PR run builds both architectures and pushes nothing**

```bash
gh run watch
```

Expected: the `build` job succeeds on both `ubuntu-latest` and `ubuntu-24.04-arm`; the `merge`
job is **skipped**; no package appears under the org's packages. This validates D8.

- [ ] **Step 3: Merge, and capture the published digest**

```bash
gh pr merge --squash
gh run watch
gh run view --log | grep -A2 "### Published"
```

Expected: the merge job succeeds and the job summary contains a single
`ghcr.io/measly-java-learning/engine-build@sha256:…` line. Record that digest.

- [ ] **Step 4: Confirm the index really is multi-arch**

```bash
docker buildx imagetools inspect ghcr.io/measly-java-learning/engine-build@sha256:<digest>
```

Expected: exactly two platform entries, `linux/amd64` and `linux/arm64`. The workflow already
asserts this; this is the out-of-band confirmation.

- [ ] **Step 5: Flip the package to public, then test anonymous pull**

In GitHub → org packages → `engine-build` → Package settings → Change visibility → Public.
Then, from a shell with no GHCR credentials:

```bash
docker logout ghcr.io
docker pull ghcr.io/measly-java-learning/engine-build@sha256:<digest>
```

Expected: pull succeeds. This settles open question 2 from the motivating note — anonymous
cross-org pull — and is the precondition for `corey-cole/djl-executorch-engine` consuming the
image at all. Note whether the visibility flip was one-time or had to be re-applied.

- [ ] **Step 6: Verify the attestation**

```bash
gh attestation verify \
  oci://ghcr.io/measly-java-learning/engine-build@sha256:<digest> \
  --owner measly-java-learning
```

Expected: verification succeeds. If this fails because the attestation is not discoverable
without `push-to-registry: true`, that is the answer to spec D7's open question — record it, and
flip `push-to-registry` to `true` in `build-multi-arch-image.yml`, then check whether GHCR shows
the referrer as an untagged package version.

- [ ] **Step 7: Check what the package listing shows as untagged**

In GitHub → org packages → `engine-build` → Versions. Expected under D4: every version carries
a tag (`sha-<short>`, `main`, or `sha-<short>-<arch>`). Record whether anything appears
untagged — an attestation referrer is the only plausible candidate.

- [ ] **Step 8: Record the answers in the spec and commit**

Replace the three bullets under "Risks and open items" that describe attestation mechanics and
package visibility as unconfirmed with what was actually observed in Steps 5–7. Leave the
AlmaLinux NEVRA-retention risk in place; it is still latent.

```bash
git add docs/superpowers/specs/2026-08-12-multi-arch-engine-build-design.md
git commit -m "docs: record first-publish findings in the design spec"
git push
```

---

## Out of scope

Confirmed non-goals from the spec, listed so they are not picked up mid-implementation:

- Migrating `measly-java-learning/djl-iree-engine` or `corey-cole/djl-executorch-engine` to the
  new pin, or deleting their per-repo container CI. That is work in those repositories.
- The `iree-runtime-dist` clang/lld image. It will call
  `build-multi-arch-image.yml` when it is added, which is why Task 2 parameterises `image-name`
  and `dockerfile` rather than hardcoding them.
- Bit-reproducible image builds.
