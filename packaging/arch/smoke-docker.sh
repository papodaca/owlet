#!/usr/bin/env bash
# Local smoke: build a .pkg.tar.zst inside archlinux:latest (mirrors release.yml).
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
  -v "${REPO_ROOT}:/workspace" \
  -w /workspace \
  archlinux:latest \
  bash -euo pipefail /workspace/packaging/arch/smoke-docker-inner.sh
