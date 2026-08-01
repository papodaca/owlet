#!/usr/bin/env bash
# Build Owlet .deb packages from a git checkout.
#
# Symlinks packaging/debian → <repo>/debian, runs dpkg-buildpackage from
# the repo root, then removes the symlink. Packages are moved into this
# directory (packaging/debian/) for convenience.
#
# Usage:
#   cd packaging/debian
#   OWLET_BACKEND=cpu ./build.sh          # cpu | vulkan | hip | all
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
OWLET_BACKEND=${OWLET_BACKEND:-all}

# Docker/CI bind-mounts often trip "dubious ownership"; allow git in this tree.
git config --global --add safe.directory "${REPO_ROOT}" 2>/dev/null || true
# Also cover the path as seen inside packaging when cwd differs.
git -C "${REPO_ROOT}" config --global --add safe.directory '*' 2>/dev/null || true

case "${OWLET_BACKEND}" in
  all|cpu|vulkan|hip) ;;
  *)
    echo "OWLET_BACKEND must be one of: all, cpu, vulkan, hip" >&2
    exit 1
    ;;
esac

# ROCm's amdgcn lld needs libxml2.so.2. Ubuntu 26.04 / Debian sid only
# ship libxml2.so.16 — install noble's libxml2 (pulls libicu74) first.
if [[ ${OWLET_BACKEND} == hip || ${OWLET_BACKEND} == all ]]; then
  if ! ldconfig -p 2>/dev/null | grep -q 'libxml2\.so\.2'; then
    if [[ ! -e /usr/lib/x86_64-linux-gnu/libxml2.so.2 && ! -e /usr/lib64/libxml2.so.2 ]]; then
      cat >&2 <<'EOF'
HIP build preflight failed: libxml2.so.2 not found.

ROCm 6.4.3's /opt/rocm/lib/llvm/bin/lld is linked against libxml2.so.2
(noble ABI). Ubuntu 26.04 / Debian sid only provide libxml2.so.16
(package libxml2-16). Install noble's libxml2 (and libicu74) alongside:

  echo "deb http://archive.ubuntu.com/ubuntu noble main" | \
    sudo tee /etc/apt/sources.list.d/noble-rocm-compat.list
  printf 'Package: libxml2 libicu74\nPin: release n=noble\nPin-Priority: 700\n' | \
    sudo tee /etc/apt/preferences.d/noble-rocm-compat
  sudo apt update
  sudo apt install libxml2

Or use packaging/debian/smoke-docker.sh / packaging/build.sh (sets this up).
EOF
      exit 1
    fi
  fi
fi

# Match Arch PKGBUILD pkgver(): tagged vX.Y.Z → X.Y.Z-1; else git count+hash.
owlet_deb_version() {
  local tag
  tag=$(git -C "${REPO_ROOT}" describe --tags --exact-match HEAD 2>/dev/null || true)
  if [[ ${tag} =~ ^v([0-9][^[:space:]]*)$ ]]; then
    printf '%s-1' "${BASH_REMATCH[1]}"
  else
    printf '0.1.0+git%s.%s-1' \
      "$(git -C "${REPO_ROOT}" rev-list --count HEAD)" \
      "$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  fi
}

# Build profiles so unselected backends skip both Build-Depends and
# binary packages (empty "owlet" must not be emitted on vulkan/hip-only).
profiles=()
case "${OWLET_BACKEND}" in
  cpu)
    profiles+=(nouvulkan nohip)
    ;;
  vulkan)
    profiles+=(nocpu nohip)
    ;;
  hip)
    profiles+=(nocpu nouvulkan)
    ;;
esac
if ((${#profiles[@]})); then
  export DEB_BUILD_PROFILES="${profiles[*]}"
fi
export OWLET_BACKEND

# Refresh the top changelog version from git (Arch-style pkgver; do not
# commit the rewritten line — build.sh regenerates it each run).
version=$(owlet_deb_version)
tmp_changelog=$(mktemp)
{
  echo "owlet (${version}) UNRELEASED; urgency=medium"
  echo
  echo "  * Initial Debian packaging (CPU / Vulkan / HIP split packages)."
  echo
  echo " -- Ethan Apodaca <papodaca@gmail.com>  $(date -R)"
} >"${tmp_changelog}"
mv "${tmp_changelog}" "${SCRIPT_DIR}/changelog"

cleanup() {
  if [[ -L "${REPO_ROOT}/debian" ]]; then
    target=$(readlink "${REPO_ROOT}/debian")
    if [[ ${target} == packaging/debian || ${target} == "${SCRIPT_DIR}" ]]; then
      rm -f "${REPO_ROOT}/debian"
    fi
  fi
}
trap cleanup EXIT

if [[ -e "${REPO_ROOT}/debian" && ! -L "${REPO_ROOT}/debian" ]]; then
  echo "Refusing to overwrite existing ${REPO_ROOT}/debian (not a symlink)." >&2
  exit 1
fi

if [[ -L "${REPO_ROOT}/debian" ]]; then
  target=$(readlink "${REPO_ROOT}/debian")
  if [[ ${target} != packaging/debian && ${target} != "${SCRIPT_DIR}" ]]; then
    echo "Refusing to replace ${REPO_ROOT}/debian → ${target}" >&2
    exit 1
  fi
fi

ln -sfn packaging/debian "${REPO_ROOT}/debian"

echo "Building owlet ${version} (OWLET_BACKEND=${OWLET_BACKEND}) from ${REPO_ROOT}"
(
  cd "${REPO_ROOT}"
  # Artifacts always land in packaging/debian/ (override_dh_builddeb).
  # Point dpkg-genbuildinfo/genchanges at that dir (-u) so they do not
  # look in the parent of the source tree (often "/" / unwritable in CI).
  # Skip automatic dbgsym .ddeb — not published on GitHub Releases.
  export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }noautodbgsym"
  dpkg-buildpackage -b -us -uc \
    "--changes-file=${SCRIPT_DIR}/owlet_${version}_amd64.changes" \
    "--buildinfo-file=${SCRIPT_DIR}/owlet_${version}_amd64.buildinfo" \
    "--buildinfo-option=-u${SCRIPT_DIR}" \
    "--changes-option=-u${SCRIPT_DIR}"
)

debs=("${SCRIPT_DIR}"/owlet*.deb)
if ((${#debs[@]} == 0)); then
  echo "No .deb artifacts found in ${SCRIPT_DIR}" >&2
  exit 1
fi
echo "Packages written to ${SCRIPT_DIR}:"
ls -1 "${SCRIPT_DIR}"/owlet*.deb