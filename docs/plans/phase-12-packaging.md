# Phase 12 — Arch Linux packaging (PKGBUILD)

## Goal

Ship in-tree Arch packaging so `makepkg` can build installable
`.pkg.tar.zst` packages for Kaki, with GPU-backend split packages.
`transcribe.cpp` is built from the bundled git submodule and statically
linked into each kaki binary (no separate `transcribe-cpp` package).

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
| transcribe.cpp | Bundled submodule statically linked in-tree; `prepare()` runs `git submodule update --init --recursive` |
| Meson wiring | Default empty `-Dtranscribe_dir=` (packaging does not set it). Option remains for optional system source trees |
| `pkgver` | Git-derived: `0.1.0.r<N>.<short-hash>` |
| Homepage / `url=` | `https://github.com/papodaca/kaki` |
| HIP amd_targets | Explicit list (no rocminfo autodetect): `gfx1100;gfx1030;gfx906;gfx90a;gfx1200;gfx1201` |
| libei | Hard `depends` (compile-in when found; better dictation UX than ydotool-only) |
| Models | Not packaged — downloaded at runtime to `$XDG_DATA_HOME/kaki/models/` |
| Test helpers | `download_cli` / `remote_cli` stay `install: false` — not packaged |
| `check()` | Metadata validators + `meson test --suite unit` only |

> **Revised Jul 2026:** dropped the separate source-only
> `transcribe-cpp` makedep / `/usr/src/transcribe.cpp` install. That
> setup was fragile for packagers; static linking the submodule matches
> the normal developer build.

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
packaging/arch/PKGBUILD (pkgbase=kaki)
        │  prepare: git submodule update --init --recursive
        │  meson setup ×N (cpu / vulkan / hip)  [no -Dtranscribe_dir]
        │  cmake sidecar builds libtranscribe.a + ggml*.a from submodule
        │  ninja ×N
        ▼
 kaki.pkg.tar.zst
 kaki-vulkan.pkg.tar.zst
 kaki-hip.pkg.tar.zst
```

```
meson option transcribe_dir
        │ empty → subprojects/transcribe.cpp (default; packaging uses this)
        │ set   → optional system source path
        ▼
cmake sidecar (custom_target) → libtranscribe.a + ggml*.a
        │
        ▼
kaki executable (static link) + shared UI / ROCm / BLAS libs
```

## Files

### `packaging/arch/PKGBUILD`

Midscroll-style split package. Key points:

- `KAKI_BACKEND={all|cpu|vulkan|hip}` selects which split packages to build
- `prepare()` initializes `subprojects/transcribe.cpp`
- Meson is invoked **without** `-Dtranscribe_dir=…`
- Each package installs `COPYING` plus `LICENSE.transcribe.cpp`

### `packaging/arch/kaki.install`

Post-install / post-upgrade / post-remove hooks for schemas, icons,
desktop database.

### Optional Meson option (already present)

```meson
option('transcribe_dir', type: 'string', value: '',
       description: 'Path to system transcribe.cpp source (empty = bundled submodule)')
```

Kept for unusual packaging setups; Arch PKGBUILD leaves it empty.

## Verification checklist

1. From a clean clone: `cd packaging/arch && KAKI_BACKEND=cpu makepkg -si`
2. Confirm `prepare()` fetched the submodule and build used
   `subprojects/transcribe.cpp` (no `/usr/src/transcribe.cpp`).
3. Repeat for `vulkan` / `hip` as needed; confirm conflict/replace prompts.
4. Unit + metadata tests run in `check()`.
5. HIP package `ldd` still shows ROCm runtime libs.
