#!/usr/bin/env bash
# Runs inside ubuntu:26.04 with the repo bind-mounted (see smoke-docker.sh).
# Invoked by smoke-docker.sh (or mirrored by .github/workflows/release.yml).
# CPU + Vulkan only — no ROCm / HIP packages.
set -euo pipefail

BACKEND=${BACKEND:?BACKEND must be set}
ROOT=${OWLET_DOCKER_ROOT:-/workspace}

case "${BACKEND}" in
  cpu|vulkan) ;;
  *)
    echo "BACKEND must be cpu or vulkan (got: ${BACKEND})" >&2
    exit 1
    ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg sudo \
  build-essential \
  meson ninja-build valac pkg-config cmake g++ git gettext \
  python3 python3-pytest \
  appstream desktop-file-utils libglib2.0-bin \
  gobject-introspection libgirepository-1.0-dev \
  libgtk-4-dev libadwaita-1-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-pulseaudio \
  libsoup-3.0-dev libsecret-1-dev libjson-glib-dev libarchive-dev libei-dev \
  libx11-dev libxext-dev libxrandr-dev libcairo2-dev libpango1.0-dev libblas-dev \
  file patchelf \
  xvfb xauth \
  gstreamer1.0-tools

# PipeWire capture plugin (optional at runtime; bundle when present).
apt-get install -y --no-install-recommends \
  gstreamer1.0-pipewire \
  || echo "Note: gstreamer1.0-pipewire unavailable; pulsesrc-only AppImage"

if [ "${BACKEND}" = vulkan ]; then
  # spirv-headers: ggml-vulkan find_package(SPIRV-Headers CONFIG REQUIRED)
  apt-get install -y --no-install-recommends \
    libvulkan-dev glslc spirv-headers
fi

useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
# Remember host ownership so the bind mount is not left as
# builder (uid 1000/1001) after the container exits.
host_uid=$(stat -c %u "${ROOT}")
host_gid=$(stat -c %g "${ROOT}")
restore_ownership() {
  chown -R "${host_uid}:${host_gid}" "${ROOT}"
  if [[ -n ${OWLET_DOCKER_GIT_DIR:-} && -d ${OWLET_DOCKER_GIT_DIR} ]]; then
    chown -R "${host_uid}:${host_gid}" "${OWLET_DOCKER_GIT_DIR}"
  fi
}
trap restore_ownership EXIT
chown -R builder:builder "${ROOT}"
# Linked worktree: builder must write the private gitdir (index, submodule).
if [[ -n ${OWLET_DOCKER_GIT_DIR:-} && -d ${OWLET_DOCKER_GIT_DIR} ]]; then
  chown -R builder:builder "${OWLET_DOCKER_GIT_DIR}"
fi

cd "${ROOT}/packaging/appimage"
sudo -u builder env \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  OWLET_BACKEND="${BACKEND}" \
  APPIMAGE_EXTRACT_AND_RUN=1 \
  HOME=/home/builder \
  ./build.sh