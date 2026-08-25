#!/usr/bin/env bash
# Runs inside ubuntu:26.04 with /workspace bind-mounted to the repo root.
# Invoked by smoke-docker.sh (or mirrored by .github/workflows/release.yml).
set -euo pipefail

BACKEND=${BACKEND:?BACKEND must be set}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg sudo \
  build-essential debhelper devscripts dpkg-dev \
  meson ninja-build valac pkg-config cmake g++ git \
  python3-pytest \
  appstream desktop-file-utils libglib2.0-bin \
  libgtk-4-dev libadwaita-1-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libsoup-3.0-dev libsecret-1-dev libjson-glib-dev libarchive-dev libei-dev \
  libx11-dev libxext-dev libxrandr-dev libcairo2-dev libpango1.0-dev libblas-dev

if [ "${BACKEND}" = vulkan ] || [ "${BACKEND}" = all ]; then
  # spirv-headers: ggml-vulkan find_package(SPIRV-Headers CONFIG REQUIRED)
  apt-get install -y --no-install-recommends \
    libvulkan-dev glslc spirv-headers
fi

if [ "${BACKEND}" = hip ] || [ "${BACKEND}" = all ]; then
  # AMD ROCm apt currently publishes jammy/noble only; pin the
  # noble suite on Ubuntu 26.04 until a resolute suite exists.
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.4.3 noble main" \
    > /etc/apt/sources.list.d/rocm.list
  printf "Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n" \
    > /etc/apt/preferences.d/rocm-pin-600
  # ROCm 6.4.3's clang/lld is linked against libxml2.so.2 (noble).
  # Ubuntu 26.04 / Debian sid only ship libxml2.so.16 (libxml2-16), so
  # pull noble's libxml2 (+ libicu74) alongside; SONAMEs coexist.
  echo "deb http://archive.ubuntu.com/ubuntu noble main" \
    > /etc/apt/sources.list.d/noble-rocm-compat.list
  printf '%s\n' \
    'Package: libxml2 libicu74' \
    'Pin: release n=noble' \
    'Pin-Priority: 700' \
    > /etc/apt/preferences.d/noble-rocm-compat
  apt-get update
  # rocm-device-libs: Recommends of rocm-llvm; required for clang HIP
  # compiler tests (--no-install-recommends would otherwise skip it).
  # libxml2: noble package providing libxml2.so.2 for /opt/rocm/.../lld.
  apt-get install -y --no-install-recommends \
    hip-dev rocm-device-libs \
    hipblas hipblas-dev rocblas rocblas-dev rocminfo rccl \
    libxml2
fi

useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
# Remember host ownership so the bind mount is not left as
# builder (uid 1000/1001) after the container exits.
host_uid=$(stat -c %u /workspace)
host_gid=$(stat -c %g /workspace)
trap 'chown -R "$host_uid:$host_gid" /workspace' EXIT
chown -R builder:builder /workspace
# Allow builder to use /opt/rocm when present
if [ -d /opt/rocm ]; then
  chmod -R a+rX /opt/rocm || true
fi

cd /workspace/packaging/debian
sudo -u builder env \
  PATH="/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  OWLET_BACKEND="${BACKEND}" \
  HOME=/home/builder \
  ./build.sh