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

# Every RUN below uses `set -eu`; pipefail completes that, so a failure on the left of a pipe
# cannot be masked by a successful right-hand side. bash is present in the base image. Without
# this, hadolint DL4006 fires on the two RUNs containing pipes.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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
