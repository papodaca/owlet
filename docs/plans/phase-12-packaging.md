# Phase 12 — Arch Linux packaging (PKGBUILD)

## Goal

Ship in-tree Arch packaging so `makepkg` can build installable
`.pkg.tar.zst` packages for Kaki, with GPU-backend split packages and a
separate `transcribe-cpp` source package consumed as a makedep.

## Motivation

Kaki is system-builds-only (no Flatpak). Arch users need a reproducible
way to install it. The GPU backend is baked into the binary at compile
time (static ggml archives), so one package cannot serve CPU / Vulkan /
HIP — Arch split packages are the idiomatic answer.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Location | In-tree under `packaging/` (not AUR-first; can publish later) |
| Source idiom | midscroll-style: `source=()`, `cd "$startdir/../.."` → repo root |
| Split packages | `pkgbase=kaki` → `kaki` (CPU), `kaki-vulkan`, `kaki-hip` |
| Conflict model | GPU variants `provides=('kaki')` + `conflicts=('kaki')`; CPU is canonical |
| transcribe.cpp | Separate `transcribe-cpp` package installs sources to `/usr/src/transcribe.cpp` |
| Meson wiring | Add `-Dtranscribe_dir=` option (empty = bundled submodule; no patch file) |
| `pkgver` | Git-derived: `0.1.0.r<N>.<short-hash>` |
| Homepage / `url=` | `https://github.com/papodaca/kaki` |
| HIP amd_targets | Explicit list (no rocminfo autodetect): `gfx1100;gfx1030;gfx906;gfx90a;gfx1200;gfx1201` |
| libei | Hard `depends` (compile-in when found; better dictation UX than ydotool-only) |
| Models | Not packaged — downloaded at runtime to `$XDG_DATA_HOME/kaki/models/` |
| Test helpers | `download_cli` / `remote_cli` stay `install: false` — not packaged |
| `check()` | Metadata validators + `meson test --suite unit` only |

## Current build facts (re-audited Jul 2026)

Trust this section over older phase docs when they disagree.

### Build system

- Meson ≥ 1.0, languages: C + Vala + C++17 (C++ via `add_languages(..., required: false)`).
- transcribe.cpp is **not** a meson `cmake.subproject()`. Root `meson.build`
  drives cmake via `custom_target` + `declare_dependency` (meson 1.11.2
  wrapper breaks Vulkan `;;;` config and HIP/nvcc detection).
- GPU backend resolved at configure time (`auto` → hip → vulkan → cpu).
  Exposed read-only as `Config.GPU_BACKEND` via `config.h`.
- Submodule pin: `subprojects/transcribe.cpp` @ `v0.1.2`
  (`https://github.com/handy-computer/transcribe.cpp`, MIT).

### Installed files (`meson install`)

| Path | Source |
| --- | --- |
| `/usr/bin/kaki` | `src/meson.build` executable |
| `/usr/bin/kaki-signal` | `data/kaki-signal.sh` (renamed, mode `0755`) |
| `/usr/share/applications/org.kaki.app.desktop` | merged from `.in` |
| `/usr/share/metainfo/org.kaki.app.metainfo.xml` | merged from `.in` |
| `/usr/share/glib-2.0/schemas/org.kaki.app.gschema.xml` | `data/` |
| `/usr/share/dbus-1/services/org.kaki.app.service` | configured from `.in` |
| `/usr/share/icons/hicolor/scalable/apps/org.kaki.app.svg` | icons |
| `/usr/share/icons/hicolor/symbolic/apps/org.kaki.app-symbolic.svg` | icons |
| `/usr/share/icons/hicolor/symbolic/apps/org.kaki.app-recording-symbolic.svg` | tray recording |

`gnome.post_install` compiles schemas / updates icon cache / desktop DB
at `meson install` time; Arch also runs the same via `kaki.install`
hooks on the live system.

### Required pkg-config deps (link / compile)

| pkg-config | Arch package |
| --- | --- |
| `gtk4` | `gtk4` |
| `libadwaita-1` ≥ 1.4 | `libadwaita` |
| `gstreamer-1.0` / `-base` / `-app` / `-audio` | `gstreamer`, `gst-plugins-base-libs` |
| `libsoup-3.0` | `libsoup3` |
| `libsecret-1` | `libsecret` |
| `json-glib-1.0` | `json-glib` |
| `libei-1.0` (optional in meson, hard depends in PKGBUILD) | `libei` |
| `cblas` / `blas` / `m` / `stdc++` (find_library) | `cblas`, `blas`, `gcc-libs` |

### Runtime plugin / tool deps (not always linked)

| Need | Arch package | Why |
| --- | --- | --- |
| `pulsesrc` | `gst-plugins-good` | Recorder primary audio source |
| `pipewiresrc` | `gst-plugin-pipewire` | Recorder fallback |
| `ydotool` / `xdotool` | same names | Keystroke fallbacks (`optdepends`) |
| `xdg-desktop-portal` | same | GlobalShortcuts portal (`optdepends`) |
| `notify-send` | `libnotify` | Used by `kaki-signal` (`optdepends`) |

Tray is hand-rolled StatusNotifierItem over GIO — **no** ayatana /
appindicator package. GNOME Shell still needs an AppIndicator /
KStatusNotifierItem extension for the icon to appear (document only).

### HIP (hard-linked, not dlopen-only)

`meson.build` finds and links `amdhip64`, `hipblas`, `rocblas`, `rccl`
(`required: false` each). Current HIP build `ldd` shows direct deps on
`libamdhip64.so.7` and `libhipblas.so.3` (rocblas / hsa-runtime
transitive). Binary will not load without those shared libs.

| Role | Arch packages |
| --- | --- |
| makedepends | `hip-runtime-amd` (or `rocm-hip-sdk`), `rocminfo`, `hipblas`, `rocblas` |
| depends | `hip-runtime-amd`, `hipblas`, `rocblas` |

ROCm on the audit host: HIP **7.2** — supports RDNA4 `gfx1200` /
`gfx1201`. If a packager's ROCm is &lt; 6.4, drop those two targets.

`PATH` for the cmake sidecar is prepended with ROCm's `bin/` (often
`/opt/rocm/bin`) so `enable_language(HIP)` finds clang; the user shell
is left alone.

### Vulkan

ggml-vulkan CMake requires `find_package(Vulkan COMPONENTS glslc REQUIRED)`.

| Role | Arch packages |
| --- | --- |
| makedepends | `vulkan-headers`, `shaderc` |
| depends | `vulkan-icd-loader` (also transitive via gtk4) |

## Architecture

```
packaging/arch-transcribe-cpp/PKGBUILD
        │ installs sources
        ▼
 /usr/src/transcribe.cpp/   ←── -Dtranscribe_dir=…
        │
packaging/arch/PKGBUILD (pkgbase=kaki)
        │  meson setup ×3 (cpu / vulkan / hip)
        │  ninja ×3
        ▼
 kaki.pkg.tar.zst
 kaki-vulkan.pkg.tar.zst
 kaki-hip.pkg.tar.zst
```

```
meson option transcribe_dir
        │ empty → subprojects/transcribe.cpp (dev default)
        │ set   → system path (packaging)
        ▼
cmake sidecar (custom_target) → libtranscribe.a + ggml*.a
        │
        ▼
kaki executable (static link) + shared UI / ROCm / BLAS libs
```

## Files to create / modify

### Modify `meson_options.txt`

Append:

```meson
option('transcribe_dir', type: 'string', value: '',
       description: 'Path to system transcribe.cpp source (empty = bundled submodule)')
```

Existing options (`gpu_backend`, `amd_targets`) stay unchanged.

### Modify `meson.build` (transcribe_src resolution)

Replace the hardcoded:

```meson
transcribe_src = meson.project_source_root() / 'subprojects' / 'transcribe.cpp'
```

with:

```meson
_transcribe_dir = get_option('transcribe_dir')
if _transcribe_dir == ''
  transcribe_src = meson.project_source_root() / 'subprojects' / 'transcribe.cpp'
else
  transcribe_src = _transcribe_dir
endif
```

`transcribe_builddir`, `transcribe_inc`, and the cmake sidecar stay as-is.
`transcribe_inc` still points at the **bundled** `include/` tree for
headers during normal submodule builds; when using a system source dir,
packagers must ensure `/usr/src/transcribe.cpp/include` exists (it will,
because the whole tree is installed). **Follow-up during implement:**
make `transcribe_inc` derive from `transcribe_src / 'include'` so the
system path and submodule path stay consistent:

```meson
transcribe_inc = include_directories(transcribe_src / 'include')
```

Note: `include_directories()` normally wants a path relative to the
current meson file; absolute system paths may need
`include_directories(include_directories: …)` via a different approach
(e.g. pass `-I` through `compile_args`). Verify during implement —
if absolute paths fail, fall back to a small wrap that adds
`-I@0@/include`.format(transcribe_src) on `transcribe_dep`.

### Create `packaging/arch-transcribe-cpp/PKGBUILD`

Source-only package (no compile of ggml here — kaki's cmake sidecar
still builds the archives).

```bash
pkgname=transcribe-cpp
pkgver=0.1.2
pkgrel=1
pkgdesc='C++ speech transcription engine sources (ggml-based) for building Kaki'
arch=('any')   # sources only
url='https://github.com/handy-computer/transcribe.cpp'
license=('MIT')
makedepends=('git')
source=("git+https://github.com/handy-computer/transcribe.cpp#tag=v${pkgver}")
sha256sums=('SKIP')

package() {
  install -d "${pkgdir}/usr/src/transcribe-cpp"
  cp -a "${srcdir}/transcribe.cpp/." "${pkgdir}/usr/src/transcribe-cpp/"
  rm -rf "${pkgdir}/usr/src/transcribe-cpp/.git"
  ln -s transcribe-cpp "${pkgdir}/usr/src/transcribe.cpp"
  install -Dm644 "${srcdir}/transcribe.cpp/LICENSE" \
    "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
```

### Create `packaging/arch/PKGBUILD`

Sketch (finalize paths / array syntax at implement time):

```bash
pkgbase=kaki
pkgname=('kaki' 'kaki-vulkan' 'kaki-hip')
pkgver=0.1.0.r0.g0000000   # overwritten by pkgver()
pkgrel=1
pkgdesc='Speech-to-text GNOME app using local transcribe.cpp (GTK4/libadwaita)'
url='https://github.com/papodaca/kaki'
license=('GPL-3.0-or-later')
arch=('x86_64')
install=kaki.install
source=()
sha256sums=()

makedepends=(
  meson ninja vala pkgconf cmake gcc git glib2
  appstream desktop-file-utils
  transcribe-cpp
  # vulkan variant:
  vulkan-headers shaderc
  # hip variant:
  hip-runtime-amd rocminfo hipblas rocblas
  # check():
  python-pytest
)

_common_depends=(
  gtk4 libadwaita gstreamer gst-plugins-base-libs
  gst-plugins-good gst-plugin-pipewire
  glib2 libsoup3 libsecret json-glib libei
  blas cblas gcc-libs
)

_common_optdepends=(
  'ydotool: keystroke injection fallback'
  'xdotool: X11 keystroke injection fallback'
  'xdg-desktop-portal: GlobalShortcuts portal'
  'libnotify: notifications from kaki-signal'
)

pkgver() {
  cd "${startdir}/../.."
  printf "0.1.0.r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

build() {
  cd "${startdir}/../.."
  local common=(--prefix=/usr --buildtype=plain
                -Dtranscribe_dir=/usr/src/transcribe.cpp)

  meson setup build-cpu    "${common[@]}" -Dgpu_backend=cpu
  meson setup build-vulkan "${common[@]}" -Dgpu_backend=vulkan
  meson setup build-hip    "${common[@]}" -Dgpu_backend=hip \
    -Damd_targets=gfx1100\;gfx1030\;gfx906\;gfx90a\;gfx1200\;gfx1201

  ninja -C build-cpu
  ninja -C build-vulkan
  ninja -C build-hip
}

check() {
  cd "${startdir}/../.."
  meson test -C build-cpu --print-errorlogs --suite unit
  # desktop / appstream / gschema validators also run under meson test
  # without a suite tag — include them via a second invocation if needed:
  meson test -C build-cpu --print-errorlogs \
    'Validate desktop file' 'Validate appstream file' 'Validate schema file' || true
}

package_kaki() {
  depends=("${_common_depends[@]}")
  optdepends=("${_common_optdepends[@]}")
  conflicts=('kaki-vulkan' 'kaki-hip')

  cd "${startdir}/../.."
  DESTDIR="${pkgdir}" meson install -C build-cpu
  install -Dm644 COPYING "${pkgdir}/usr/share/licenses/${pkgname}/COPYING"
}

package_kaki-vulkan() {
  pkgdesc+=' (Vulkan backend)'
  depends=("${_common_depends[@]}" vulkan-icd-loader)
  optdepends=("${_common_optdepends[@]}")
  provides=('kaki')
  conflicts=('kaki')

  cd "${startdir}/../.."
  DESTDIR="${pkgdir}" meson install -C build-vulkan
  install -Dm644 COPYING "${pkgdir}/usr/share/licenses/${pkgname}/COPYING"
}

package_kaki-hip() {
  pkgdesc+=' (AMD HIP/ROCm backend)'
  depends=("${_common_depends[@]}" hip-runtime-amd hipblas rocblas)
  optdepends=("${_common_optdepends[@]}")
  provides=('kaki')
  conflicts=('kaki')

  cd "${startdir}/../.."
  DESTDIR="${pkgdir}" meson install -C build-hip
  install -Dm644 COPYING "${pkgdir}/usr/share/licenses/${pkgname}/COPYING"
}
```

Notes for implement:

- `makepkg --pkg kaki` builds only the CPU package function's packaging
  step, but `build()` still configures all three — consider gating HIP
  setup behind an env var (`_build_hip=0`) if iteration is too slow.
- Semicolon escaping in `-Damd_targets=` must survive makepkg's shell —
  verify with a dry run.
- `arch=('x86_64')` for all three initially (HIP/ROCm is x86_64-only on
  Arch). CPU/Vulkan can widen to `aarch64` later.

### Create `packaging/arch/kaki.install`

```bash
post_install() {
  glib-compile-schemas /usr/share/glib-2.0/schemas
  gtk-update-icon-cache -qtf /usr/share/icons/hicolor
  update-desktop-database -q /usr/share/applications
}

post_upgrade() { post_install; }

post_remove() {
  glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
  gtk-update-icon-cache -qtf /usr/share/icons/hicolor 2>/dev/null || true
  update-desktop-database -q /usr/share/applications 2>/dev/null || true
}
```

### Update `docs/plans/README.md`

Add phase 12 to the phases table.

## Out of scope

- Publishing to AUR / generating `.SRCINFO` (optional follow-up)
- Flatpak / Snap / Debian / Fedora packaging
- Shipping Whisper GGUF models in the package
- Building shared `libtranscribe.so` (stay with static sidecar)
- Fixing placeholder AppStream metadata (`example.org` screenshots etc.)
  — useful for a polished release, not required for a working PKGBUILD
- Phase 8 / 9 product work

## Verification checklist

1. Install `transcribe-cpp` from `packaging/arch-transcribe-cpp` via
   `makepkg -si`; confirm `/usr/src/transcribe.cpp/include/transcribe.h`
   exists.
2. From `packaging/arch`: `makepkg -f` produces three `.pkg.tar.zst`
   files.
3. `namcap *.pkg.tar.zst` — fix missing/unused deps (watch `cblas` /
   `blas` split, gtk4's transitive `vulkan-icd-loader`, ROCm sonames).
4. `meson test -C build-cpu --suite unit` passes under the packaging
   configure (`-Dtranscribe_dir=…`).
5. Install `kaki` in a clean chroot; `/usr/bin/kaki` and
   `/usr/bin/kaki-signal` exist; schemas compile; desktop entry shows.
6. `ldd` on `kaki-hip` binary lists `libamdhip64` / `libhipblas`; binary
   fails to load without those packages (expected — hard link).
7. On AMD hardware, `kaki-hip` runs local transcription; on any GPU with
   a Vulkan ICD, `kaki-vulkan` does the same.
8. Confirm RDNA4 targets build with `hipcc --version` ≥ 6.4 (host has
   7.2).

## Commit sequence

1. Meson: add `transcribe_dir` option + resolve `transcribe_src` /
   include path from it.
2. Add `packaging/arch-transcribe-cpp/PKGBUILD`.
3. Add `packaging/arch/PKGBUILD` + `kaki.install`.
4. Docs: this phase file + README index row (this commit may land first
   as the plan-only commit).

## Open risks

| Risk | Mitigation |
| --- | --- |
| Absolute `transcribe_dir` breaks `include_directories()` | Fall back to `-I` compile_args on `transcribe_dep` |
| HIP multi-arch compile is slow / huge binary | Env gate; document `makepkg --pkg`; strip via Arch defaults |
| `rccl` missing on some ROCm installs | Already `required: false` — leave optional |
| Metainfo placeholders fail strict appstream validate | Keep `--no-net` test; fix metadata in a release polish pass |
| Tray icons need installed theme paths | Document that uninstalled builds won't show SNI icons |
