#!/usr/bin/env bash
# Pinned sherpa-onnx FetchContent archives (v1.13.6 sidecar, CPU static).
#
# Upstream cmake looks for these filenames in $HOME/Downloads,
# CMAKE_SOURCE_DIR (the submodule), CMAKE_BINARY_DIR (the sidecar build
# dir), and /tmp. Packaging seeds CMAKE_BINARY_DIR so network-isolated
# distro builds do not hit GitHub/GitLab at configure time.
#
# Usage:
#   ./sherpa-onnx-archives.sh dump
#   ./sherpa-onnx-archives.sh fetch [--dir CACHE]
#   ./sherpa-onnx-archives.sh seed [--from DIR] DEST [DEST...]
#
# Sourced from the Arch PKGBUILD:
#   . packaging/sherpa-onnx-archives.sh
#   owlet_sherpa_init "$CARCH"
# Do not `set -e` here — this file is sourced by PKGBUILD.

_owlet_sherpa_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OWLET_SHERPA_ARCHIVES_DIR=${OWLET_SHERPA_ARCHIVES_DIR:-"${_owlet_sherpa_self}/.cache/sherpa-onnx-archives"}

# filename | sha256 | url | arch (any, x86_64, aarch64)
_owlet_sherpa_rows() {
  cat <<'EOF'
kaldi-native-fbank-1.22.3.tar.gz	9176cc66fc7ce1edf85cf355b06e320c57db6297df74277f575183468893cf61	https://github.com/csukuangfj/kaldi-native-fbank/archive/refs/tags/v1.22.3.tar.gz	any
kaldi-decoder-0.3.0.tar.gz	b9f34cfb4fd3b1344100eead79ef4d37aa15962274b9e3056de345021f76a1b0	https://github.com/k2-fsa/kaldi-decoder/archive/refs/tags/v0.3.0.tar.gz	any
simple-sentencepiece-0.7.tar.gz	1748a822060a35baa9f6609f84efc8eb54dc0e74b9ece3d82367b7119fdc75af	https://github.com/pkufool/simple-sentencepiece/archive/refs/tags/v0.7.tar.gz	any
json-3.12.0.tar.gz	4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187	https://github.com/nlohmann/json/archive/refs/tags/v3.12.0.tar.gz	any
espeak-ng-ed530aa113046142eb5115cf2fc9157854d0ffe1.zip	e4e262cbe34f7fe21f91f1ba3397f2728e1f30eafbae7853f2b753a9ed13f0dd	https://github.com/csukuangfj/espeak-ng/archive/ed530aa113046142eb5115cf2fc9157854d0ffe1.zip	any
piper-phonemize-f3ff95afc03640bc1399e113e83361192a2fafb4.zip	d9cca4e2bdc7d6dd8dffb96a4668283dbd3f77a9c194a3e530c1e8eba9406a5d	https://github.com/csukuangfj/piper-phonemize/archive/f3ff95afc03640bc1399e113e83361192a2fafb4.zip	any
eigen-5.0.1.tar.gz	e9c326dc8c05cd1e044c71f30f1b2e34a6161a3b6ecf445d56b53ff1669e3dec	https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz	any
openfst-1.8.5-2026-07-09.tar.gz	2ff712a32952fcb01d351121a6bc8ccf4fdc6b2aa06ce8df2b3095dedd518c0e	https://github.com/csukuangfj/openfst/archive/refs/tags/v1.8.5-2026-07-09.tar.gz	any
kissfft-febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip	497103e664168ebe39580b757adbe616f6cf85a16572af581ca7bc42d0ab13fd	https://github.com/mborgerding/kissfft/archive/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec.zip	any
kaldifst-1.8.0.tar.gz	3f247b7e5a2409071202f5e2bc6200060f66728c0a3443c03923ad2723e040b3	https://github.com/k2-fsa/kaldifst/archive/refs/tags/v1.8.0.tar.gz	any
onnxruntime-linux-x64-static_lib-1.27.1-glibc2_17.zip	6b4df7fc46d3367b6be73fdea80dee323b9dc9eaa8dc50136a33d8524e7f06bb	https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-linux-x64-static_lib-1.27.1-glibc2_17.zip	x86_64
onnxruntime-linux-aarch64-static_lib-1.27.1-glibc2_17.zip	051131cfe80d07257631311f0b1f726b7302e85e1c7e2176cb84e461eea1fe27	https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-linux-aarch64-static_lib-1.27.1-glibc2_17.zip	aarch64
EOF
}

owlet_sherpa_normalize_arch() {
  case "${1:-}" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    any) printf 'any\n' ;;
    '') uname -m ;;
    *)
      echo "unsupported sherpa archive arch: $1" >&2
      return 1
      ;;
  esac
}

owlet_sherpa_init() {
  local host
  host=$(owlet_sherpa_normalize_arch "${1:-}")
  owlet_sherpa_source_entries=()
  owlet_sherpa_sha256s=()
  owlet_sherpa_filenames=()
  local filename sha256 url arch
  while IFS=$'\t' read -r filename sha256 url arch; do
    [[ -n ${filename} ]] || continue
    if [[ ${arch} != any && ${arch} != "${host}" ]]; then
      continue
    fi
    owlet_sherpa_source_entries+=("${filename}::${url}")
    owlet_sherpa_sha256s+=("${sha256}")
    owlet_sherpa_filenames+=("${filename}")
  done < <(_owlet_sherpa_rows)
}

_owlet_sherpa_find() {
  local filename=$1
  local from=${2:-}
  local candidate
  for candidate in \
    ${from:+"${from}/${filename}"} \
    "${OWLET_SHERPA_ARCHIVES_DIR}/${filename}" \
    "${HOME}/Downloads/${filename}"; do
    if [[ -f ${candidate} ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

_owlet_sherpa_verify() {
  local path=$1
  local expected=$2
  local actual
  actual=$(sha256sum "${path}" | awk '{print $1}')
  if [[ ${actual} != "${expected}" ]]; then
    echo "sha256 mismatch for ${path}: expected ${expected}, got ${actual}" >&2
    return 1
  fi
}

_owlet_sherpa_download() {
  local dest=$1
  local url=$2
  mkdir -p "$(dirname "${dest}")"
  local tmp="${dest}.part"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "${tmp}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${tmp}" "${url}"
  else
    echo "need curl or wget to fetch ${url}" >&2
    return 1
  fi
  mv -f "${tmp}" "${dest}"
}

owlet_sherpa_fetch() {
  local cache=${1:-${OWLET_SHERPA_ARCHIVES_DIR}}
  local host
  host=$(owlet_sherpa_normalize_arch "${2:-}")
  mkdir -p "${cache}"
  local filename sha256 url arch dest
  while IFS=$'\t' read -r filename sha256 url arch; do
    [[ -n ${filename} ]] || continue
    if [[ ${arch} != any && ${arch} != "${host}" ]]; then
      continue
    fi
    dest="${cache}/${filename}"
    if [[ -f ${dest} ]]; then
      _owlet_sherpa_verify "${dest}" "${sha256}"
      continue
    fi
    echo "fetching ${filename}"
    _owlet_sherpa_download "${dest}" "${url}"
    _owlet_sherpa_verify "${dest}" "${sha256}"
  done < <(_owlet_sherpa_rows)
}

owlet_sherpa_seed() {
  local from=""
  if [[ ${1:-} == --from ]]; then
    from=$2
    shift 2
  fi
  if [[ $# -lt 1 ]]; then
    echo "usage: owlet_sherpa_seed [--from DIR] DEST [DEST...]" >&2
    return 1
  fi
  local host
  host=$(owlet_sherpa_normalize_arch "")
  local filename sha256 url arch src dest
  while IFS=$'\t' read -r filename sha256 url arch; do
    [[ -n ${filename} ]] || continue
    if [[ ${arch} != any && ${arch} != "${host}" ]]; then
      continue
    fi
    src=$(_owlet_sherpa_find "${filename}" "${from}" || true)
    downloaded=0
    if [[ -z ${src} ]]; then
      mkdir -p "${OWLET_SHERPA_ARCHIVES_DIR}"
      src="${OWLET_SHERPA_ARCHIVES_DIR}/${filename}"
      echo "fetching ${filename}"
      _owlet_sherpa_download "${src}" "${url}"
      downloaded=1
    fi
    # --from staging (Arch $srcdir) is already checksummed by the packager.
    if [[ ${downloaded} -eq 1 || -z ${from} ]]; then
      _owlet_sherpa_verify "${src}" "${sha256}"
    fi
    for dest in "$@"; do
      mkdir -p "${dest}"
      cp -f "${src}" "${dest}/${filename}"
    done
  done < <(_owlet_sherpa_rows)
}

owlet_sherpa_dump() {
  _owlet_sherpa_rows
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  cmd=${1:-}
  shift || true
  case "${cmd}" in
    dump)
      owlet_sherpa_dump
      ;;
    fetch)
      cache=${OWLET_SHERPA_ARCHIVES_DIR}
      if [[ ${1:-} == --dir ]]; then
        cache=$2
        shift 2
      fi
      owlet_sherpa_fetch "${cache}" "${1:-}"
      ;;
    seed)
      owlet_sherpa_seed "$@"
      ;;
    *)
      echo "usage: $0 dump|fetch|seed ..." >&2
      exit 2
      ;;
  esac
fi
