#!/usr/bin/env bash
# Local smoke: build a .deb inside ubuntu:26.04 (mirrors release.yml).
# Usage: ./smoke-docker.sh cpu|vulkan|hip
set -euo pipefail

BACKEND=${1:?usage: $0 cpu|vulkan|hip}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

case "${BACKEND}" in
  cpu|vulkan|hip) ;;
  *)
    echo "backend must be cpu, vulkan, or hip" >&2
    exit 1
    ;;
esac

docker run --rm \
  -e "BACKEND=${BACKEND}" \
  -e CMAKE_BUILD_PARALLEL_LEVEL \
  -v "${REPO_ROOT}:/workspace" \
  -w /workspace \
  ubuntu:26.04 \
  bash -euo pipefail /workspace/packaging/debian/smoke-docker-inner.sh
