#!/usr/bin/env bash
# Local packaging smoke for Arch, Debian, and AppImage Docker builds.
#
# Long HIP/Vulkan Docker builds often outlive agent tool timeouts; this
# script tees a log, verifies expected artifacts, and prints a short
# report you can paste back.
#
# Usage:
#   ./build.sh all                     # arch + debian × cpu→vulkan→hip; appimage × cpu→vulkan
#   ./build.sh arch                    # all Arch backends
#   ./build.sh arch vulkan             # one Arch backend
#   ./build.sh debian                  # all Debian backends
#   ./build.sh debian cpu              # one Debian backend
#   ./build.sh appimage                # cpu then vulkan AppImages (no hip)
#   ./build.sh appimage cpu            # one AppImage backend
#
# Requires: docker; archlinux:latest and/or ubuntu:26.04 pull access;
# ~10–20G free for HIP.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR=${LOG_DIR:-"${SCRIPT_DIR}/test-logs"}
mkdir -p "${LOG_DIR}"

usage() {
  cat >&2 <<'EOF'
usage: build.sh all
       build.sh <arch|debian> [cpu|vulkan|hip|all]
       build.sh appimage [cpu|vulkan|all]

Examples:
  ./build.sh all
  ./build.sh arch vulkan
  ./build.sh debian cpu
  ./build.sh appimage
  ./build.sh appimage cpu
EOF
  exit 1
}

DISTRO=${1:-}
BACKEND=${2:-}

case "${DISTRO}" in
  ''|-h|--help) usage ;;
  all)
    if [[ -n ${BACKEND} ]]; then
      usage
    fi
    ;;
  arch|debian)
    BACKEND=${BACKEND:-all}
    case "${BACKEND}" in
      cpu|vulkan|hip|all) ;;
      *) usage ;;
    esac
    ;;
  appimage)
    BACKEND=${BACKEND:-all}
    case "${BACKEND}" in
      cpu|vulkan|all) ;;
      hip)
        echo "AppImage packaging does not support HIP (use arch or debian)." >&2
        usage
        ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac

ARCH_DIR="${SCRIPT_DIR}/arch"
DEBIAN_DIR="${SCRIPT_DIR}/debian"
APPIMAGE_DIR="${SCRIPT_DIR}/appimage"
# Host uname -m for AppImage artifact names (x86_64 / aarch64).
HOST_ARCH=$(uname -m)

pkg_dir_for() {
  case "$1" in
    arch) echo "${ARCH_DIR}" ;;
    debian) echo "${DEBIAN_DIR}" ;;
    appimage) echo "${APPIMAGE_DIR}" ;;
  esac
}

expected_pkgs_for() {
  local distro=$1 be=$2
  case "${distro}/${be}" in
    arch/cpu) echo "owlet-[0-9]*.pkg.tar.zst" ;;
    arch/vulkan) echo "owlet-vulkan-*.pkg.tar.zst" ;;
    arch/hip) echo "owlet-hip-*.pkg.tar.zst" ;;
    debian/cpu) echo "owlet_*.deb" ;;
    debian/vulkan) echo "owlet-vulkan_*.deb" ;;
    debian/hip) echo "owlet-hip_*.deb" ;;
    appimage/cpu) echo "Owlet-*-${HOST_ARCH}-cpu.AppImage" ;;
    appimage/vulkan) echo "Owlet-*-${HOST_ARCH}-vulkan.AppImage" ;;
  esac
}

forbidden_pkgs_for() {
  local distro=$1 be=$2
  case "${distro}/${be}" in
    arch/cpu) echo "owlet-vulkan-*.pkg.tar.zst owlet-hip-*.pkg.tar.zst" ;;
    arch/vulkan) echo "owlet-[0-9]*.pkg.tar.zst owlet-hip-*.pkg.tar.zst" ;;
    arch/hip) echo "owlet-[0-9]*.pkg.tar.zst owlet-vulkan-*.pkg.tar.zst" ;;
    debian/cpu) echo "owlet-vulkan_*.deb owlet-hip_*.deb" ;;
    debian/vulkan) echo "owlet_*.deb owlet-hip_*.deb" ;;
    debian/hip) echo "owlet_*.deb owlet-vulkan_*.deb" ;;
    appimage/cpu) echo "Owlet-*-${HOST_ARCH}-vulkan.AppImage" ;;
    appimage/vulkan) echo "Owlet-*-${HOST_ARCH}-cpu.AppImage" ;;
  esac
}

list_matching() {
  # $1 = package dir, $2 = glob; may expand to nothing.
  local dir=$1 pattern=$2
  shopt -s nullglob
  local matches=("${dir}"/${pattern})
  shopt -u nullglob
  if ((${#matches[@]})); then
    printf '%s\n' "${matches[@]}"
  fi
}

inspect_pkg() {
  local distro=$1 f=$2
  case "${distro}" in
    debian)
      if command -v dpkg-deb >/dev/null 2>&1; then
        echo "---- dpkg-deb -I ----"
        dpkg-deb -I "${f}" | sed -n '1,40p' || true
        echo "---- Depends / Conflicts / Provides ----"
        dpkg-deb -f "${f}" Package Version Architecture Depends Conflicts Provides Recommends Suggests || true
      fi
      ;;
    arch)
      if command -v bsdtar >/dev/null 2>&1; then
        echo "---- .PKGINFO (bsdtar) ----"
        bsdtar -xOf "${f}" .PKGINFO 2>/dev/null | sed -n '1,40p' || true
      elif tar -tf "${f}" >/dev/null 2>&1; then
        echo "---- archive members (first 20) ----"
        tar -tf "${f}" 2>/dev/null | head -n 20 || true
      fi
      ;;
    appimage)
      if command -v file >/dev/null 2>&1; then
        echo "---- file ----"
        file "${f}" || true
      fi
      if [[ -x ${f} ]]; then
        echo "---- AppImage --appimage-help (extract-and-run) ----"
        APPIMAGE_EXTRACT_AND_RUN=1 "${f}" --appimage-help 2>&1 | sed -n '1,30p' || true
      fi
      ;;
  esac
}

verify_backend() {
  local distro=$1 be=$2
  local pkg_dir
  pkg_dir=$(pkg_dir_for "${distro}")
  local ok=1
  local f

  echo
  echo "=== verify ${distro}/${be} ==="

  local expected
  expected=$(expected_pkgs_for "${distro}" "${be}")
  local found=()
  while IFS= read -r f; do
    [[ -n ${f} ]] && found+=("${f}")
  done < <(list_matching "${pkg_dir}" "${expected}")

  if ((${#found[@]} == 0)); then
    echo "FAIL: no package matching ${expected}"
    ok=0
  else
    for f in "${found[@]}"; do
      echo "OK: $(basename "${f}") ($(du -h "${f}" | awk '{print $1}'))"
      inspect_pkg "${distro}" "${f}"
    done
  fi

  local forbidden
  forbidden=$(forbidden_pkgs_for "${distro}" "${be}")
  local bad
  for pattern in ${forbidden}; do
    while IFS= read -r bad; do
      if [[ -n ${bad} ]]; then
        echo "WARN: unexpected leftover package $(basename "${bad}") (remove if stale)"
      fi
    done < <(list_matching "${pkg_dir}" "${pattern}")
  done

  if ((ok)); then
    echo "RESULT: ${distro}/${be} PASS"
    return 0
  fi
  echo "RESULT: ${distro}/${be} FAIL"
  return 1
}

clean_backend_artifacts() {
  local distro=$1 be=$2
  local pkg_dir
  pkg_dir=$(pkg_dir_for "${distro}")
  case "${distro}/${be}" in
    arch/cpu)
      # Versioned CPU package: owlet-<digit>… (not owlet-vulkan / owlet-hip).
      rm -f "${pkg_dir}"/owlet-[0-9]*.pkg.tar.zst
      ;;
    arch/vulkan)
      rm -f "${pkg_dir}"/owlet-vulkan-*.pkg.tar.zst
      ;;
    arch/hip)
      rm -f "${pkg_dir}"/owlet-hip-*.pkg.tar.zst
      ;;
    debian/cpu)
      rm -f "${pkg_dir}"/owlet_*.deb
      rm -f "${pkg_dir}"/owlet_*.changes "${pkg_dir}"/owlet_*.buildinfo
      ;;
    debian/vulkan)
      rm -f "${pkg_dir}"/owlet-vulkan_*.deb
      ;;
    debian/hip)
      rm -f "${pkg_dir}"/owlet-hip_*.deb
      ;;
    appimage/cpu)
      rm -f "${pkg_dir}"/Owlet-*-"${HOST_ARCH}"-cpu.AppImage
      ;;
    appimage/vulkan)
      rm -f "${pkg_dir}"/Owlet-*-"${HOST_ARCH}"-vulkan.AppImage
      ;;
  esac
}

error_patterns() {
  echo 'CMake Error|SPIRV-Headers|relocation R_|error while loading|cannot find ROCm|libxml2\.so|collect2:|dpkg-buildpackage: error|HIP compiler|ERROR: A failure occurred|FAILED:|linuxdeploy|AppImage not produced'
}

run_one() {
  local distro=$1 be=$2
  local pkg_dir
  pkg_dir=$(pkg_dir_for "${distro}")
  local log="${LOG_DIR}/${distro}-${be}-${STAMP}.log"
  echo
  echo "################################################################"
  echo "# Building ${distro}/${be}"
  echo "# Log: ${log}"
  echo "# Started: $(date -R)"
  echo "################################################################"

  clean_backend_artifacts "${distro}" "${be}"

  set +e
  (
    cd "${pkg_dir}"
    ./smoke-docker.sh "${be}"
  ) 2>&1 | tee "${log}"
  local rc=${PIPESTATUS[0]}
  set -e

  echo "# Finished: $(date -R) (exit=${rc})" | tee -a "${log}"
  if ((rc != 0)); then
    echo "RESULT: ${distro}/${be} BUILD FAILED (see ${log})"
    echo "---- last 40 log lines ----"
    tail -n 40 "${log}" || true
    local pat
    pat=$(error_patterns)
    echo "---- matched error lines ----"
    if command -v rg >/dev/null 2>&1; then
      rg -n "${pat}" "${log}" | tail -n 30 || true
    else
      grep -nE "${pat}" "${log}" | tail -n 30 || true
    fi
    return "${rc}"
  fi

  verify_backend "${distro}" "${be}"
}

run_distro() {
  local distro=$1 be=$2
  local failures=0
  if [[ ${be} == all ]]; then
    local backends
    case "${distro}" in
      appimage) backends=(cpu vulkan) ;;
      *) backends=(cpu vulkan hip) ;;
    esac
    local b
    for b in "${backends[@]}"; do
      if ! run_one "${distro}" "${b}"; then
        failures=$((failures + 1))
        echo "Stopping on first failure (already ran: ${distro}/${b})." >&2
        break
      fi
    done
  else
    if ! run_one "${distro}" "${be}"; then
      failures=1
    fi
  fi
  return "${failures}"
}

list_artifacts() {
  echo "---- Arch packages ----"
  ls -lh "${ARCH_DIR}"/owlet*.pkg.tar.zst 2>/dev/null || echo "(none)"
  echo "---- Debian packages ----"
  ls -lh "${DEBIAN_DIR}"/owlet*.deb 2>/dev/null || echo "(none)"
  echo "---- AppImages ----"
  ls -lh "${APPIMAGE_DIR}"/Owlet-*.AppImage 2>/dev/null || echo "(none)"
}

echo "Repo: ${REPO_ROOT}"
echo "Packaging: ${SCRIPT_DIR}"
echo "Target: ${DISTRO}${BACKEND:+/${BACKEND}}"
echo "Logs: ${LOG_DIR}"
df -h / /home 2>/dev/null || df -h .

failures=0
if [[ ${DISTRO} == all ]]; then
  for d in arch debian appimage; do
    if ! run_distro "${d}" all; then
      failures=$((failures + 1))
      echo "Stopping on first failure (distro=${d})." >&2
      break
    fi
  done
else
  if ! run_distro "${DISTRO}" "${BACKEND}"; then
    failures=1
  fi
fi

echo
echo "================================================================"
if ((failures == 0)); then
  echo "OVERALL: PASS"
  echo "Paste-back hint: ${DISTRO}${BACKEND:+/${BACKEND}} PASS; logs in ${LOG_DIR}"
  list_artifacts
  exit 0
fi
echo "OVERALL: FAIL (${failures} failure group(s))"
echo "Paste-back hint: attach/tail the log under ${LOG_DIR}"
list_artifacts
exit 1
