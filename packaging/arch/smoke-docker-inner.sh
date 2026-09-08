#!/usr/bin/env bash
# Runs inside archlinux:latest with /workspace bind-mounted to the repo root.
# Invoked by smoke-docker.sh (or mirrored by .github/workflows/release.yml).
set -euo pipefail

BACKEND=${BACKEND:?BACKEND must be set}

pacman -Syu --noconfirm --needed base-devel git sudo
sed -i "s/[[:space:]]debug/ !debug/" /etc/makepkg.conf

useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
# Remember host ownership so the bind mount is not left as
# builder (uid 1000/1001) after the container exits.
host_uid=$(stat -c %u /workspace)
host_gid=$(stat -c %g /workspace)
trap 'chown -R "$host_uid:$host_gid" /workspace' EXIT
chown -R builder:builder /workspace

cd /workspace/packaging/arch
sudo -u builder env \
  OWLET_BACKEND="${BACKEND}" \
  CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-}" \
  makepkg -s --noconfirm
