#!/usr/bin/env bash
# Local Debian packaging smoke you can run outside the agent.
#
# Long HIP/Vulkan Docker builds often outlive agent tool timeouts; this
# script tees a log, verifies expected .deb artifacts, and prints a
# short report you can paste back.
#
# Usage:
#   ./test_deb_build.sh              # default: hip (the unfinished smoke)
#   ./test_deb_build.sh cpu
#   ./test_deb_build.sh vulkan
#   ./test_deb_build.sh hip
#   ./test_deb_build.sh all          # sequential cpu → vulkan → hip
#
# Requires: docker, ubuntu:26.04 pull access, ~10–20G free for HIP.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
BACKEND=${1:-hip}
STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR=${LOG_DIR:-"${SCRIPT_DIR}/test-logs"}
mkdir -p "${LOG_DIR}"

usage() {
  echo "usage: $0 [cpu|vulkan|hip|all]" >&2
  exit 1
}

case "${BACKEND}" in
  cpu|vulkan|hip|all) ;;
  -h|--help) usage ;;
  *) usage ;;
esac

expected_debs_for() {
  case "$1" in
    cpu) echo "owlet_*.deb" ;;
    vulkan) echo "owlet-vulkan_*.deb" ;;
    hip) echo "owlet-hip_*.deb" ;;
  esac
}

forbidden_debs_for() {
  # With build profiles, unselected backends must not emit packages.
  case "$1" in
    cpu) echo "owlet-vulkan_*.deb owlet-hip_*.deb" ;;
    vulkan) echo "owlet_*.deb owlet-hip_*.deb" ;;
    hip) echo "owlet_*.deb owlet-vulkan_*.deb" ;;
  esac
}

list_matching() {
  # $1 = glob relative to SCRIPT_DIR; may expand to nothing.
  local pattern=$1
  shopt -s nullglob
  local matches=("${SCRIPT_DIR}"/${pattern})
  shopt -u nullglob
  if ((${#matches[@]})); then
    printf '%s\n' "${matches[@]}"
  fi
}

verify_backend() {
  local be=$1
  local ok=1
  local f

  echo
  echo "=== verify backend=${be} ==="

  local expected
  expected=$(expected_debs_for "${be}")
  local found=()
  # shellcheck disable=SC2086
  while IFS= read -r f; do
    [[ -n ${f} ]] && found+=("${f}")
  done < <(list_matching "${expected}")

  if ((${#found[@]} == 0)); then
    echo "FAIL: no package matching ${expected}"
    ok=0
  else
    for f in "${found[@]}"; do
      echo "OK: $(basename "${f}") ($(du -h "${f}" | awk '{print $1}'))"
      echo "---- dpkg-deb -I ----"
      dpkg-deb -I "${f}" | sed -n '1,40p' || true
      echo "---- Depends / Conflicts / Provides ----"
      dpkg-deb -f "${f}" Package Version Architecture Depends Conflicts Provides Recommends Suggests || true
    done
  fi

  local forbidden
  forbidden=$(forbidden_debs_for "${be}")
  local bad
  for pattern in ${forbidden}; do
    while IFS= read -r bad; do
      if [[ -n ${bad} ]]; then
        # Ignore stale artifacts from earlier backends in the same dir
        # only when their mtime is older than this run's log — still
        # flag anything matching the forbidden name that exists.
        echo "WARN: unexpected leftover package $(basename "${bad}") (remove if stale)"
      fi
    done < <(list_matching "${pattern}")
  done

  if ((ok)); then
    echo "RESULT: ${be} PASS"
    return 0
  fi
  echo "RESULT: ${be} FAIL"
  return 1
}

run_one() {
  local be=$1
  local log="${LOG_DIR}/deb-${be}-${STAMP}.log"
  echo
  echo "################################################################"
  echo "# Building backend=${be}"
  echo "# Log: ${log}"
  echo "# Started: $(date -R)"
  echo "################################################################"

  # Drop only this backend's previous .deb so verify is meaningful, but
  # leave other backends' artifacts alone (useful for `all`).
  case "${be}" in
    cpu)
      rm -f "${SCRIPT_DIR}"/owlet_*.deb
      rm -f "${SCRIPT_DIR}"/owlet_*.changes "${SCRIPT_DIR}"/owlet_*.buildinfo
      ;;
    vulkan)
      rm -f "${SCRIPT_DIR}"/owlet-vulkan_*.deb
      ;;
    hip)
      rm -f "${SCRIPT_DIR}"/owlet-hip_*.deb
      ;;
  esac

  set +e
  (
    cd "${SCRIPT_DIR}"
    ./smoke-docker.sh "${be}"
  ) 2>&1 | tee "${log}"
  local rc=${PIPESTATUS[0]}
  set -e

  echo "# Finished: $(date -R) (exit=${rc})" | tee -a "${log}"
  if ((rc != 0)); then
    echo "RESULT: ${be} BUILD FAILED (see ${log})"
    # Prefer the real failure over Vala/gcc warning spam at the end of a
    # long ninja log.
    echo "---- last 40 log lines ----"
    tail -n 40 "${log}" || true
    if command -v rg >/dev/null 2>&1; then
      if rg -n "CMake Error|relocation R_|error while loading|cannot find|FAILED:|collect2:|dpkg-buildpackage: error" "${log}" >/dev/null 2>&1; then
        echo "---- matched error lines ----"
        rg -n "CMake Error|relocation R_|error while loading|cannot find ROCm|libxml2\\.so|collect2:|dpkg-buildpackage: error|HIP compiler" "${log}" | tail -n 30 || true
      fi
    else
      echo "---- matched error lines ----"
      grep -nE "CMake Error|relocation R_|error while loading|cannot find ROCm|libxml2\\.so|collect2:|dpkg-buildpackage: error|HIP compiler" "${log}" | tail -n 30 || true
    fi
    return "${rc}"
  fi

  verify_backend "${be}"
}

echo "Repo: ${REPO_ROOT}"
echo "Debian dir: ${SCRIPT_DIR}"
echo "Backend: ${BACKEND}"
echo "Logs: ${LOG_DIR}"
df -h / /home 2>/dev/null || df -h .

failures=0
if [[ ${BACKEND} == all ]]; then
  for be in cpu vulkan hip; do
    if ! run_one "${be}"; then
      failures=$((failures + 1))
      echo "Stopping on first failure (already ran: up to ${be})." >&2
      break
    fi
  done
else
  if ! run_one "${BACKEND}"; then
    failures=1
  fi
fi

echo
echo "================================================================"
if ((failures == 0)); then
  echo "OVERALL: PASS"
  echo "Paste-back hint: backend=${BACKEND} PASS; logs in ${LOG_DIR}"
  ls -lh "${SCRIPT_DIR}"/owlet*.deb 2>/dev/null || true
  exit 0
fi
echo "OVERALL: FAIL (${failures} backend failure(s))"
echo "Paste-back hint: attach/tail the log under ${LOG_DIR}"
ls -lh "${SCRIPT_DIR}"/owlet*.deb 2>/dev/null || true
exit 1