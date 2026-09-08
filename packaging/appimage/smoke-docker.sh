#!/usr/bin/env bash
# Local smoke: build an AppImage inside ubuntu:26.04 (mirrors release.yml).
# Usage: ./smoke-docker.sh cpu|vulkan
set -euo pipefail

BACKEND=${1:?usage: $0 cpu|vulkan}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

case "${BACKEND}" in
  cpu|vulkan) ;;
  *)
    echo "backend must be cpu or vulkan (HIP AppImages are not supported)" >&2
    exit 1
    ;;
esac

# Ordinary clones (CI): mount at /workspace. Linked worktrees have a .git
# *file* pointing at an absolute path under the main repo's .git, and the
# submodule uses a relative gitdir that only resolves when the tree is
# mounted at its real host path — so bind-mount those paths as-is.
docker_args=(
  --rm
  -e "BACKEND=${BACKEND}"
  -e CMAKE_BUILD_PARALLEL_LEVEL
)

if [[ -f ${REPO_ROOT}/.git ]]; then
  git_common=$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir)
  git_dir=$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-dir)
  docker_args+=(
    -e "OWLET_DOCKER_ROOT=${REPO_ROOT}"
    -e "OWLET_DOCKER_GIT_DIR=${git_dir}"
    -v "${REPO_ROOT}:${REPO_ROOT}"
    -v "${git_common}:${git_common}"
    -w "${REPO_ROOT}"
  )
  inner="${REPO_ROOT}/packaging/appimage/smoke-docker-inner.sh"
else
  docker_args+=(
    -e "OWLET_DOCKER_ROOT=/workspace"
    -v "${REPO_ROOT}:/workspace"
    -w /workspace
  )
  inner=/workspace/packaging/appimage/smoke-docker-inner.sh
fi

docker run "${docker_args[@]}" \
  ubuntu:26.04 \
  bash -euo pipefail "${inner}"
