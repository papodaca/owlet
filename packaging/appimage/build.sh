#!/usr/bin/env bash
# Build Owlet AppImages from a git checkout (CPU or Vulkan only).
#
# Usage:
#   cd packaging/appimage
#   OWLET_BACKEND=cpu ./build.sh          # cpu | vulkan
#
# Produces: Owlet-$VERSION-$ARCH-$OWLET_BACKEND.AppImage in this directory
# (ARCH is uname -m: x86_64 or aarch64).
# Requires: meson, ninja, valac, cmake, curl, file, desktop-file-utils,
# patchelf, GTK4/libadwaita/GStreamer build deps; for vulkan also
# libvulkan-dev, glslc, spirv-headers. Runtime GStreamer plugins used for
# bundling: gstreamer1.0-plugins-good (+ pipewire plugin if present).
#
# AppImages built on Ubuntu 26.04 target that glibc floor (libadwaita ≥ 1.8).
# HIP/ROCm AppImages are intentionally unsupported.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
OWLET_BACKEND=${OWLET_BACKEND:-}
HOST_ARCH=$(uname -m)

# Docker/CI bind-mounts often trip "dubious ownership"; allow git in this tree.
git config --global --add safe.directory "${REPO_ROOT}" 2>/dev/null || true
git -C "${REPO_ROOT}" config --global --add safe.directory '*' 2>/dev/null || true

case "${OWLET_BACKEND}" in
  cpu|vulkan) ;;
  hip|all|'')
    cat >&2 <<EOF
OWLET_BACKEND must be cpu or vulkan (got: ${OWLET_BACKEND:-<empty>}).

AppImage packaging does not support HIP/ROCm or building all backends in
one invocation. Use Arch or Debian packaging for HIP; for both AppImages
run: ./packaging/build.sh appimage
EOF
    exit 1
    ;;
  *)
    echo "OWLET_BACKEND must be cpu or vulkan (got: ${OWLET_BACKEND})" >&2
    exit 1
    ;;
esac

case "${HOST_ARCH}" in
  x86_64|aarch64) ;;
  *)
    echo "AppImage packaging supports x86_64 and aarch64 (got: ${HOST_ARCH})" >&2
    exit 1
    ;;
esac

# Debian multiarch libdir triplet for this host.
case "${HOST_ARCH}" in
  x86_64) MULTIARCH_TRIPLET=x86_64-linux-gnu ;;
  aarch64) MULTIARCH_TRIPLET=aarch64-linux-gnu ;;
esac

# Pinned tooling (prefer tagged linuxdeploy over floating continuous).
LINUXDEPLOY_VERSION=${LINUXDEPLOY_VERSION:-1-alpha-20251107-1}
LINUXDEPLOY_BIN="linuxdeploy-${HOST_ARCH}.AppImage"
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_VERSION}/${LINUXDEPLOY_BIN}"
# Plugin scripts: pin to known commits (github API at packaging time).
GTK_PLUGIN_URL="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5/linuxdeploy-plugin-gtk.sh"
GSTREAMER_PLUGIN_URL="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gstreamer/2a2e67491c32/linuxdeploy-plugin-gstreamer.sh"

CACHE_DIR=${LINUXDEPLOY_CACHE_DIR:-"${SCRIPT_DIR}/.linuxdeploy-cache"}
APPDIR="${SCRIPT_DIR}/AppDir"
BUILDDIR="${SCRIPT_DIR}/builddir-${OWLET_BACKEND}"
GST_STAGE="${SCRIPT_DIR}/.gst-plugins-minimal"

owlet_appimage_version() {
  local tag
  tag=$(git -C "${REPO_ROOT}" describe --tags --exact-match HEAD 2>/dev/null || true)
  if [[ ${tag} =~ ^v([0-9][^[:space:]]*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '0.1.0+git%s.%s' \
      "$(git -C "${REPO_ROOT}" rev-list --count HEAD)" \
      "$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  fi
}

patch_gtk_plugin() {
  # Ubuntu 26.04 / GTK 4.22+: no /usr/lib/.../gtk-4.0 modules tree, and
  # gdk-pixbuf no longer ships a 2.10.0/loaders dir (built-in loaders).
  # Upstream linuxdeploy-plugin-gtk still assumes both exist.
  local gtk=$1
  local tmp

  if ! grep -q 'OWLET_SKIP_MISSING_GTK_MODULES' "${gtk}"; then
    tmp=$(mktemp)
    # Patch only copy_lib_tree's loop (unique mkdir uses LD_GTK_LIBRARY_PATH).
    awk '
      BEGIN { patched = 0 }
      {
        if (!patched && $0 ~ /for elem in "\$\{src\[@\]\}"; do/) {
          print
          getline nextline
          if (nextline ~ /LD_GTK_LIBRARY_PATH/) {
            print "        # OWLET_SKIP_MISSING_GTK_MODULES"
            print "        if [ ! -e \"$elem\" ]; then"
            print "            echo \"Skipping missing path: $elem\""
            print "            continue"
            print "        fi"
            print nextline
            patched = 1
            next
          }
          print nextline
          next
        }
        print
      }
      END {
        if (!patched) {
          print "patch_gtk_plugin: failed to locate copy_lib_tree loop" > "/dev/stderr"
          exit 1
        }
      }
    ' "${gtk}" >"${tmp}"
    mv "${tmp}" "${gtk}"
  fi

  if ! grep -q 'OWLET_SKIP_MISSING_PIXBUF_LOADERS' "${gtk}"; then
    tmp=$(mktemp)
    python3 - "${gtk}" "${tmp}" <<'PY'
import sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text()
old = '''if [ -x "$gdk_pixbuf_query" ]; then
    echo "Updating pixbuf cache in $APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}"
    "$gdk_pixbuf_query" > "$APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}"
else
    echo "WARNING: gdk-pixbuf-query-loaders not found"
fi
if [ ! -f "$APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}" ]; then
    echo "WARNING: loaders.cache file is missing"
fi
sed -i "s|$gdk_pixbuf_moduledir/||g" "$APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}"'''
new = '''# OWLET_SKIP_MISSING_PIXBUF_LOADERS
if [ -d "$gdk_pixbuf_binarydir" ] && [ -x "$gdk_pixbuf_query" ]; then
    echo "Updating pixbuf cache in $APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}"
    mkdir -p "$(dirname "$APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}")"
    "$gdk_pixbuf_query" > "$APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}"
    sed -i "s|$gdk_pixbuf_moduledir/||g" "$APPDIR/${gdk_pixbuf_cache_file/$LD_GTK_LIBRARY_PATH//usr/lib}"
elif [ ! -d "$gdk_pixbuf_binarydir" ]; then
    echo "WARNING: gdk-pixbuf loaders dir missing (built-in loaders); not setting GDK_PIXBUF_MODULE_FILE"
    sed -i "/GDK_PIXBUF_MODULE_FILE/d" "$HOOKFILE"
else
    echo "WARNING: gdk-pixbuf-query-loaders not found"
fi'''
if old not in text:
    raise SystemExit('patch_gtk_plugin: gdk-pixbuf cache block not found')
dst.write_text(text.replace(old, new, 1))
PY
    mv "${tmp}" "${gtk}"
  fi

  chmod +x "${gtk}"
}

fetch_tooling() {
  mkdir -p "${CACHE_DIR}"
  local ld="${CACHE_DIR}/${LINUXDEPLOY_BIN}"
  local gtk="${CACHE_DIR}/linuxdeploy-plugin-gtk.sh"
  local gst="${CACHE_DIR}/linuxdeploy-plugin-gstreamer.sh"

  if [[ ! -f ${ld} ]]; then
    echo "Downloading linuxdeploy ${LINUXDEPLOY_VERSION} (${HOST_ARCH})…"
    curl -fL --retry 3 -o "${ld}.partial" "${LINUXDEPLOY_URL}"
    mv "${ld}.partial" "${ld}"
  fi
  if [[ ! -f ${gtk} ]]; then
    echo "Downloading linuxdeploy-plugin-gtk…"
    curl -fL --retry 3 -o "${gtk}.partial" "${GTK_PLUGIN_URL}"
    mv "${gtk}.partial" "${gtk}"
  fi
  if [[ ! -f ${gst} ]]; then
    echo "Downloading linuxdeploy-plugin-gstreamer…"
    curl -fL --retry 3 -o "${gst}.partial" "${GSTREAMER_PLUGIN_URL}"
    mv "${gst}.partial" "${gst}"
  fi
  patch_gtk_plugin "${gtk}"
  chmod +x "${ld}" "${gtk}" "${gst}"

  # Extract once so we can call appimagetool directly after stripping
  # driver libs (a second linuxdeploy --output pass re-deploys them).
  if [[ ! -x ${CACHE_DIR}/squashfs-root/plugins/linuxdeploy-plugin-appimage/usr/bin/appimagetool ]]; then
    echo "Extracting linuxdeploy (for appimagetool)…"
    rm -rf "${CACHE_DIR}/squashfs-root"
    (
      cd "${CACHE_DIR}"
      APPIMAGE_EXTRACT_AND_RUN=1 "./${LINUXDEPLOY_BIN}" --appimage-extract >/dev/null
    )
  fi
}

assert_no_graphics_driver_libs() {
  local hits
  hits=$(find "${APPDIR}" \( \
    -name 'libvulkan.so*' -o \
    -name 'libvulkan_*.so*' -o \
    -name 'libVkLayer*.so*' -o \
    -name 'libGLX_mesa.so*' -o \
    -name 'libEGL_mesa.so*' -o \
    -name 'libgallium*.so*' -o \
    -name 'libdrm_amdgpu.so*' -o \
    -name 'libdrm_radeon.so*' -o \
    -name 'libdrm_intel.so*' -o \
    -name 'libdrm_nouveau.so*' -o \
    -name 'libnvidia-*.so*' -o \
    -name 'libcuda.so*' \
  \) 2>/dev/null || true)
  if [[ -d ${APPDIR}/usr/lib/dri || -d ${APPDIR}/usr/lib/${MULTIARCH_TRIPLET}/dri || -d ${APPDIR}/usr/share/vulkan ]]; then
    hits+=$'\n'"dri-or-vulkan-share-dir"
  fi
  if [[ -n ${hits} ]]; then
    echo "Graphics driver / Vulkan ICD libs still present in AppDir after strip:" >&2
    printf '%s\n' "${hits}" >&2
    exit 1
  fi
}

stage_minimal_gstreamer_plugins() {
  # Curated set for capture (pulsesrc/pipewiresrc → appsink) plus enough
  # playback plugins for MediaFile start/stop .ogg tones. Avoid shipping
  # the full host "good/bad" plugin tree.
  local host_plugins=""
  if [[ -d /usr/lib/${MULTIARCH_TRIPLET}/gstreamer-1.0 ]]; then
    host_plugins=/usr/lib/${MULTIARCH_TRIPLET}/gstreamer-1.0
  elif [[ -d /usr/lib/gstreamer-1.0 ]]; then
    host_plugins=/usr/lib/gstreamer-1.0
  else
    echo "No host GStreamer plugin directory found" >&2
    exit 1
  fi

  rm -rf "${GST_STAGE}"
  mkdir -p "${GST_STAGE}"

  local names=(
    libgstcoreelements.so
    libgstapp.so
    libgstaudioconvert.so
    libgstaudioresample.so
    libgstpulseaudio.so
    libgstpipewire.so
    libgstplayback.so
    libgsttypefindfunctions.so
    libgstogg.so
    libgstvorbis.so
    libgstaudioparsers.so
    libgstautodetect.so
    libgstvolume.so
    libgstalsa.so
  )
  local n src
  for n in "${names[@]}"; do
    src="${host_plugins}/${n}"
    if [[ -f ${src} ]]; then
      cp -a "${src}" "${GST_STAGE}/"
    else
      case "${n}" in
        libgstpipewire.so|libgstalsa.so)
          echo "Note: optional GStreamer plugin missing, skipping: ${n}"
          ;;
        *)
          echo "Required GStreamer plugin missing: ${src}" >&2
          exit 1
          ;;
      esac
    fi
  done
}

strip_graphics_driver_libs() {
  # Prefer host Vulkan loader + ICD / Mesa drivers. Remove anything
  # linuxdeploy pulled in that would pin a build-host GPU stack.
  local patterns=(
    'libvulkan.so*'
    'libvulkan_*.so*'
    'libVkLayer*.so*'
    'libGLX_mesa.so*'
    'libEGL_mesa.so*'
    'libgallium*.so*'
    'libdrm_amdgpu.so*'
    'libdrm_radeon.so*'
    'libdrm_intel.so*'
    'libdrm_nouveau.so*'
    'libnvidia-*.so*'
    'libcuda.so*'
  )
  local pat
  for pat in "${patterns[@]}"; do
    find "${APPDIR}" -type f -name "${pat}" -print -delete 2>/dev/null || true
    find "${APPDIR}" -type l -name "${pat}" -print -delete 2>/dev/null || true
  done
  rm -rf \
    "${APPDIR}/usr/lib/dri" \
    "${APPDIR}/usr/lib/${MULTIARCH_TRIPLET}/dri" \
    "${APPDIR}/usr/share/vulkan" \
    "${APPDIR}/usr/lib/vulkan" \
    "${APPDIR}/usr/lib/${MULTIARCH_TRIPLET}/vulkan" \
    "${APPDIR}/usr/share/doc/libvulkan1" \
    "${APPDIR}/usr/share/doc/libvulkan-dev" \
    2>/dev/null || true
}

neutralize_gdk_backend_x11() {
  # linuxdeploy-plugin-gtk injects GDK_BACKEND=x11 ("Crash with Wayland…").
  # Drop that so Wayland hosts can use the native backend.
  local hook="${APPDIR}/apprun-hooks/linuxdeploy-plugin-gtk.sh"
  if [[ -f ${hook} ]]; then
    sed -i '/^export GDK_BACKEND=x11/d' "${hook}"
    if ! grep -q 'GDK_BACKEND' "${hook}"; then
      cat >>"${hook}" <<'EOF'
# Prefer Wayland when available; fall back to X11 (do not force x11).
# Uncomment to force X11: export GDK_BACKEND=x11
EOF
    fi
    echo "Neutralized forced GDK_BACKEND=x11 in gtk AppRun hook"
  fi
}

smoke_appimage() {
  local image=$1
  export APPIMAGE_EXTRACT_AND_RUN=1
  echo "Smoke: AppImage --help (may need display; tolerating GUI-only failures)…"
  if command -v xvfb-run >/dev/null 2>&1; then
    xvfb-run -a "${image}" --help >/tmp/owlet-appimage-help.txt 2>&1 \
      || xvfb-run -a "${image}" --gapplication-help >/tmp/owlet-appimage-help.txt 2>&1 \
      || true
  else
    "${image}" --help >/tmp/owlet-appimage-help.txt 2>&1 \
      || "${image}" --gapplication-help >/tmp/owlet-appimage-help.txt 2>&1 \
      || true
  fi
  if grep -qiE 'Usage|Application Options|GApplication|help' /tmp/owlet-appimage-help.txt 2>/dev/null; then
    echo "Smoke: help output looks OK"
  else
    echo "Smoke: help probe inconclusive (AppImage still produced); tail:"
    tail -n 20 /tmp/owlet-appimage-help.txt || true
  fi

  if [[ -x ${APPDIR}/usr/bin/owlet ]] && command -v gst-inspect-1.0 >/dev/null 2>&1; then
    echo "Smoke: gst-inspect pulsesrc against bundled plugins…"
    GST_PLUGIN_SYSTEM_PATH_1_0="${APPDIR}/usr/lib/gstreamer-1.0" \
      GST_PLUGIN_PATH_1_0="${APPDIR}/usr/lib/gstreamer-1.0" \
      GST_REGISTRY_REUSE_PLUGIN_SCANNER=no \
      gst-inspect-1.0 pulsesrc >/tmp/owlet-gst-pulsesrc.txt 2>&1 \
      && echo "Smoke: pulsesrc OK" \
      || {
        echo "WARN: gst-inspect pulsesrc failed:" >&2
        tail -n 30 /tmp/owlet-gst-pulsesrc.txt >&2 || true
      }
  fi
}

# --- main -------------------------------------------------------------------

git -C "${REPO_ROOT}" submodule update --init --recursive

VERSION=$(owlet_appimage_version)
OUTPUT_NAME="Owlet-${VERSION}-${HOST_ARCH}-${OWLET_BACKEND}.AppImage"
OUTPUT_PATH="${SCRIPT_DIR}/${OUTPUT_NAME}"

echo "Building ${OUTPUT_NAME} (OWLET_BACKEND=${OWLET_BACKEND}) from ${REPO_ROOT}"

rm -rf "${APPDIR}" "${BUILDDIR}"
rm -f "${SCRIPT_DIR}/Owlet-"*-"${HOST_ARCH}-${OWLET_BACKEND}.AppImage"
mkdir -p "${APPDIR}"

fetch_tooling
stage_minimal_gstreamer_plugins

meson setup "${BUILDDIR}" "${REPO_ROOT}" \
  --prefix=/usr \
  --buildtype=release \
  "-Dgpu_backend=${OWLET_BACKEND}"
"${REPO_ROOT}/packaging/sherpa-onnx-archives.sh" seed \
  "${BUILDDIR}/subprojects/sherpa-onnx"
ninja -C "${BUILDDIR}"
DESTDIR="${APPDIR}" meson install -C "${BUILDDIR}"

DESKTOP_FILE="${APPDIR}/usr/share/applications/im.apodaca.owlet.desktop"
ICON_SVG="${APPDIR}/usr/share/icons/hicolor/scalable/apps/im.apodaca.owlet.svg"
if [[ ! -f ${DESKTOP_FILE} ]]; then
  echo "Missing desktop file after meson install: ${DESKTOP_FILE}" >&2
  exit 1
fi
if [[ ! -f ${ICON_SVG} ]]; then
  # Prefer any installed scalable app icon.
  ICON_SVG=$(find "${APPDIR}/usr/share/icons" -name 'im.apodaca.owlet.svg' | head -n1 || true)
fi
if [[ -z ${ICON_SVG} || ! -f ${ICON_SVG} ]]; then
  echo "Missing app icon after meson install" >&2
  exit 1
fi

# Stage license and third-party notice files into the AppDir doc tree
DOC_DIR="${APPDIR}/usr/share/doc/owlet"
mkdir -p "${DOC_DIR}"
cp -f "${REPO_ROOT}/COPYING" "${DOC_DIR}/copyright-GPL-3.0"
if [[ -f "${REPO_ROOT}/subprojects/transcribe.cpp/LICENSE" ]]; then
  cp -f "${REPO_ROOT}/subprojects/transcribe.cpp/LICENSE" "${DOC_DIR}/copyright-transcribe.cpp"
fi
if [[ -f "${REPO_ROOT}/subprojects/sherpa-onnx/LICENSE" ]]; then
  cp -f "${REPO_ROOT}/subprojects/sherpa-onnx/LICENSE" "${DOC_DIR}/copyright-sherpa-onnx"
fi
if [[ -f "${REPO_ROOT}/packaging/notices/kokoro-en-v0_19.NOTICE" ]]; then
  cp -f "${REPO_ROOT}/packaging/notices/kokoro-en-v0_19.NOTICE" \
    "${DOC_DIR}/copyright-kokoro-en-v0_19"
fi

export APPIMAGE_EXTRACT_AND_RUN=1
export DEPLOY_GTK_VERSION=4
export GSTREAMER_PLUGINS_DIR="${GST_STAGE}"
# Do not pull gst-plugins-bad via the plugin's optional path (unused in
# current plugin script, but keep unset for clarity).
unset GSTREAMER_INCLUDE_BAD_PLUGINS || true

LINUXDEPLOY="${CACHE_DIR}/${LINUXDEPLOY_BIN}"
# Plugins must live next to linuxdeploy (or on PATH).
cp -f "${CACHE_DIR}/linuxdeploy-plugin-gtk.sh" \
  "${CACHE_DIR}/linuxdeploy-plugin-gstreamer.sh" \
  "$(dirname "${LINUXDEPLOY}")/" 2>/dev/null || true

EXCLUDE_ARGS=(
  --exclude-library='libvulkan.so*'
  --exclude-library='libvulkan_*.so*'
  --exclude-library='libVkLayer*.so*'
  --exclude-library='libGLX_mesa.so*'
  --exclude-library='libEGL_mesa.so*'
  --exclude-library='libgallium*.so*'
  --exclude-library='libnvidia-*.so*'
  --exclude-library='libcuda.so*'
)

# Populate AppDir only — do not --output yet. A later linuxdeploy pack
# pass re-scans and can put excluded Vulkan/Mesa libs back.
(
  cd "${SCRIPT_DIR}"
  env APPIMAGE_EXTRACT_AND_RUN=1 \
    DEPLOY_GTK_VERSION=4 \
    GSTREAMER_PLUGINS_DIR="${GST_STAGE}" \
    "${LINUXDEPLOY}" \
    --appdir "${APPDIR}" \
    --executable "${APPDIR}/usr/bin/owlet" \
    --desktop-file "${DESKTOP_FILE}" \
    --icon-file "${ICON_SVG}" \
    --plugin gtk \
    --plugin gstreamer \
    "${EXCLUDE_ARGS[@]}"
)

neutralize_gdk_backend_x11
strip_graphics_driver_libs
assert_no_graphics_driver_libs

# Pack the cleaned AppDir as-is (no dependency redeploy).
APPIMAGETOOL="${CACHE_DIR}/squashfs-root/plugins/linuxdeploy-plugin-appimage/usr/bin/appimagetool"
if [[ ! -x ${APPIMAGETOOL} ]]; then
  echo "appimagetool missing after linuxdeploy extract: ${APPIMAGETOOL}" >&2
  exit 1
fi
(
  cd "${SCRIPT_DIR}"
  env ARCH="${HOST_ARCH}" \
    VERSION="${VERSION}" \
    APPIMAGE_EXTRACT_AND_RUN=1 \
    "${APPIMAGETOOL}" "${APPDIR}" "${OUTPUT_PATH}"
)

if [[ ! -f ${OUTPUT_PATH} ]]; then
  echo "AppImage not produced: expected ${OUTPUT_PATH}" >&2
  ls -la "${SCRIPT_DIR}" >&2 || true
  exit 1
fi
chmod +x "${OUTPUT_PATH}"

smoke_appimage "${OUTPUT_PATH}"

echo "AppImage written to ${OUTPUT_PATH}"
ls -lh "${OUTPUT_PATH}"