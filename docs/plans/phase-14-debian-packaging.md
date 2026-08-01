# Phase 14 — Debian / Ubuntu packaging (`.deb`)

> **Status:** complete (CPU + Vulkan + HIP `.deb` smoke green on
> `ubuntu:26.04` via `packaging/debian/smoke-docker.sh` /
> `test_deb_build.sh`)

## Goal

Ship in-tree Debian packaging so `dpkg-buildpackage` (via a thin
wrapper) can build installable `.deb` packages for Owlet, with
GPU-backend split packages. `transcribe.cpp` is built from the bundled
git submodule and statically linked into each owlet binary (no separate
`transcribe-cpp` package). Mirror the Arch split from
[`phase-12-packaging.md`](phase-12-packaging.md).

## Motivation

Owlet is system-builds-only (no Flatpak). Debian and Ubuntu users need a
reproducible way to install it, parallel to Arch’s `packaging/arch/`.
The GPU backend is baked into the binary at compile time (static ggml
archives), so one package cannot serve CPU / Vulkan / HIP — three
mutually exclusive binary packages are the idiomatic answer.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Location | In-tree under `packaging/debian/` (not repo-root `debian/` first; not PPA-first) |
| Source idiom | Wrapper symlinks `packaging/debian` → repo-root `debian`, runs `dpkg-buildpackage` from repo root, cleans up — same spirit as Arch midscroll `cd "$startdir/../.."` |
| Split packages | Source package `owlet` → binaries `owlet` (CPU), `owlet-vulkan`, `owlet-hip` |
| Conflict model | GPU variants `Provides: owlet` + `Conflicts: owlet`; CPU is canonical. dpkg treats Provides when evaluating Conflicts, so vulkan and hip also exclude each other |
| Backend select | `OWLET_BACKEND={all\|cpu\|vulkan\|hip}` (default `all`), same env UX as Arch PKGBUILD |
| transcribe.cpp | Bundled submodule statically linked; `debian/rules` (or wrapper) runs `git submodule update --init --recursive` |
| Meson wiring | Default empty `-Dtranscribe_dir=` (packaging does not set it) |
| Version | Git-derived Debian version, e.g. `0.1.0+git<rN>.<short-hash>-1` (or equivalent `0.1.0~rN.hash-1`); regenerate `changelog` entry from git like Arch `pkgver()` |
| Homepage | `https://github.com/papodaca/owlet` |
| License packaging | `debian/copyright` covers GPL-3.0-or-later (Owlet) + MIT (transcribe.cpp submodule); also install license texts under `/usr/share/doc/<pkg>/` |
| HIP amd_targets | Explicit list (no rocminfo autodetect): `gfx1100;gfx1030;gfx906;gfx90a;gfx1200;gfx1201` |
| HIP deps source | **AMD ROCm apt repo** (`repo.radeon.com`) — distro universe ROCm alone is too old/incomplete for these targets |
| Target releases | **Ubuntu 26.04 (resolute)** and **Debian sid** — require libadwaita ≥ 1.8 (`Adw.ShortcutsDialog`); Ubuntu 24.04 / Debian 13 are too old |
| libei | Soft: `libei-dev` Build-Depends (compile-in only when `EI_DEVICE_CAP_TEXT` exists, libei ≥ 1.6); runtime `libei1` is `Recommends` (Ubuntu 26.04 / Debian sid ship 1.5 → ydotool/xdotool fallback). `${shlibs:Depends}` pulls `libei1` automatically when linked |
| Models | Not packaged — downloaded at runtime to `$XDG_DATA_HOME/owlet/models/` |
| Test helpers | `download_cli` / `remote_cli` stay `install: false` — not packaged |
| Tests in package build | Metadata validators + `meson test --suite unit` only (CPU build when `all`) |
| Delivery (first pass) | In-tree build docs + GitHub Release `.deb` artifacts (Ubuntu 26.04 CI); no Launchpad PPA / OBS |
| Maintainer scripts | Prefer dpkg triggers (`libglib2.0`, gtk icon cache, desktop DB) over custom `postinst`; add scripts only if triggers prove insufficient |

## Current build facts (shared with phase 12)

Trust [`phase-12-packaging.md`](phase-12-packaging.md) “Current build facts”
and `AGENTS.md` over older phase docs. Summary for Debian packaging:

### Installed files (`meson install`)

| Path | Source |
| --- | --- |
| `/usr/bin/owlet` | `src/meson.build` executable |
| `/usr/bin/owlet-signal` | `data/owlet-signal.sh` (renamed, mode `0755`) |
| `/usr/share/applications/im.apodaca.owlet.desktop` | merged from `.in` |
| `/usr/share/metainfo/im.apodaca.owlet.metainfo.xml` | merged from `.in` |
| `/usr/share/glib-2.0/schemas/im.apodaca.owlet.gschema.xml` | `data/` |
| `/usr/share/dbus-1/services/im.apodaca.owlet.service` | configured from `.in` |
| `/usr/share/icons/hicolor/scalable/apps/im.apodaca.owlet.svg` | icons |
| `/usr/share/icons/hicolor/symbolic/apps/im.apodaca.owlet-symbolic.svg` | icons |
| `/usr/share/icons/hicolor/symbolic/apps/im.apodaca.owlet-recording-symbolic.svg` | tray recording |

`gnome.post_install` runs schema / icon / desktop updates at
`meson install` time; on the live system, Debian triggers should refresh
the same caches when packages are installed or removed.

### Required pkg-config deps → Debian/Ubuntu packages

Confirm exact names on Ubuntu 26.04 and Debian sid during implementation
(`apt-cache search` / `dpkg -S`). Expected mapping:

| pkg-config / need | Debian / Ubuntu package (expected) |
| --- | --- |
| `gtk4` | `libgtk-4-dev` (build), `libgtk-4-1` (runtime) |
| `libadwaita-1` ≥ 1.8 | `libadwaita-1-dev (>= 1.8)`, `libadwaita-1-0` |
| `gstreamer-1.0` / `-base` / `-app` / `-audio` | `libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev`, … |
| `libsoup-3.0` | `libsoup-3.0-dev`, `libsoup-3.0-0` |
| `libsecret-1` | `libsecret-1-dev`, `libsecret-1-0` |
| `json-glib-1.0` | `libjson-glib-dev`, `libjson-glib-1.0-0` |
| `libei-1.0` | `libei-dev`, `libei1` (or current SONAME package) |
| `x11` / `xext` / cairo / pangocairo | `libx11-dev`, `libxext-dev`, `libcairo2-dev`, `libpangocairo-1.0-dev` |
| `cblas` / `blas` / `stdc++` | `libblas-dev` (+ cblas as needed), `libstdc++6` |
| toolchain | `meson`, `ninja-build`, `valac`, `pkg-config`, `cmake`, `g++`, `git` |
| Vulkan ggml | `libvulkan-dev`, `glslc`, **`spirv-headers`** (CMake `find_package(SPIRV-Headers CONFIG)`) |
| validators | `appstream` / `appstream-util`, `desktop-file-utils`, `libglib2.0-bin` |
| unit tests | `python3-pytest` (prefer over a host Arch `.venv` bind-mounted into Docker) |

### Runtime plugin / tool deps

| Need | Debian / Ubuntu package (expected) | Why |
| --- | --- | --- |
| `pulsesrc` | `gstreamer1.0-plugins-good` | Recorder primary audio source |
| `pipewiresrc` | `gstreamer1.0-pipewire` | Recorder fallback |
| `ydotool` / `xdotool` | same names | Keystroke fallbacks (`Suggests` / `Recommends`) |
| `xdg-desktop-portal` | same | GlobalShortcuts portal |
| `notify-send` | `libnotify-bin` | Used by `owlet-signal` |

Tray is hand-rolled StatusNotifierItem over GIO — **no** ayatana /
appindicator package. GNOME Shell still needs an AppIndicator /
KStatusNotifierItem extension (document only).

### Vulkan

| Role | Packages (expected) |
| --- | --- |
| Build-Depends | `libvulkan-dev`, `glslc` (shaderc), `spirv-headers` (ggml-vulkan `find_package(SPIRV-Headers)`) |
| Depends | `libvulkan1` (often transitive via gtk4) |

### HIP (AMD ROCm apt repo)

Document enabling AMD’s Ubuntu/Debian ROCm apt source before building or
installing `owlet-hip`. Prefer meta / concrete packages from that repo
(e.g. `hipcc` / `hip-dev`, `rocm-device-libs` — only a Recommends of
`rocm-llvm`, required for clang HIP compiler tests when using
`--no-install-recommends` — `hipblas` / `-dev`, `rocblas` / `-dev`,
`rocminfo`, runtime libs such as `libamdhip64` / `hip-runtime-amd`) —
**pin exact names** after checking current ROCm release notes. AMD ROCm
apt currently publishes jammy/noble only — pin the **noble** suite on
Ubuntu 26.04 / Debian sid until a newer suite exists.

Also install noble's **`libxml2`** (pulls `libicu74`): ROCm 6.4.3's
`/opt/rocm/lib/llvm/bin/lld` is linked against `libxml2.so.2`, while
Ubuntu 26.04 / Debian sid only ship `libxml2.so.16` (`libxml2-16`). Do
**not** put `libxml2` in `debian/control` Build-Depends (package name
absent on resolute/sid); smoke-docker / README add a noble pin instead.
`build.sh` preflights for `libxml2.so.2` on HIP builds.

`meson.build` links `amdhip64`, `hipblas`, `rocblas`, `rccl` when found.
Binary will not load without the ROCm shared libs.

`PATH` for the cmake sidecar is prepended with ROCm’s `bin/` (often
`/opt/rocm/bin`) so `enable_language(HIP)` finds clang; the user shell
is left alone. Packaging should ensure that path is visible during the
package build (env in `debian/rules` if needed).

HIP objects must be built with **`-fPIC`**: Debian
`DEB_BUILD_MAINT_OPTIONS=hardening=+all` links a PIE `owlet`, and
`CMAKE_HIP_FLAGS` does not inherit dpkg `CXXFLAGS`. `meson.build`
passes `-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON`,
`-DCMAKE_HIP_FLAGS_INIT=-fPIC`, and `-DCMAKE_HIP_FLAGS:STRING=-fPIC`
(typed cache entries — untyped `-D` values are `UNINITIALIZED` and
`enable_language(HIP)` can wipe them).

`dh_shlibdeps` needs `-l/opt/rocm/lib --ignore-missing-info` when
building HIP: ROCm libs are outside multiarch paths, and ROCm .debs
often lack shlibs/symbols. Explicit `Depends` cover the runtime.

If a packager’s ROCm is &lt; 6.4, drop `gfx1200` / `gfx1201` from
`amd_targets` (same note as Arch).

## Architecture

```
packaging/debian/build.sh
        │  symlink packaging/debian → <repo>/debian
        │  dpkg-buildpackage -b … from repo root
        ▼
debian/rules (OWLET_BACKEND)
        │  submodule update --init --recursive
        │  meson setup ×N (cpu / vulkan / hip)  [no -Dtranscribe_dir]
        │  cmake sidecar builds libtranscribe.a + ggml*.a from submodule
        │  ninja ×N
        │  DESTDIR=debian/<pkg> meson install ×N
        ▼
 owlet_*.deb
 owlet-vulkan_*.deb
 owlet-hip_*.deb
```

```
meson option transcribe_dir
        │ empty → subprojects/transcribe.cpp (default; packaging uses this)
        │ set   → optional system source path
        ▼
cmake sidecar (custom_target) → libtranscribe.a + ggml*.a
        │
        ▼
owlet executable (static link) + shared UI / ROCm / BLAS libs
```

Why not a single `dh_auto_configure`: GPU backends are compile-time;
each binary package needs its own meson builddir (same constraint as
Arch). Override `dh_auto_configure` / `build` / `test` / `install` /
`clean` accordingly; install each backend with
`DESTDIR=debian/<binary-package>` so files never collide in `debian/tmp`.

## Files to add

### `packaging/debian/control`

- Source stanza: `Source: owlet`, `Section: sound` (or `utils`),
  `Priority: optional`, `Standards-Version`, `Homepage`,
  `Rules-Requires-Root: no`, full `Build-Depends`.
- Three `Package:` stanzas with `Architecture: amd64` initially (match
  Arch `x86_64`; widen later if desired).
- `owlet`: CPU; `Conflicts: owlet-vulkan, owlet-hip` (or rely on reciprocal
  `Conflicts: owlet` from the others — pick one clear scheme and document
  it; prefer matching Arch semantics).
- `owlet-vulkan` / `owlet-hip`: `Provides: owlet`, `Conflicts: owlet`,
  plus backend-specific Depends.
- `Recommends` for libei1, xdg-desktop-portal, libnotify-bin;
  `Suggests` for ydotool, xdotool (dictation fallbacks when libei
  < 1.6 / TEXT unavailable).
- Optional: build-profiles so `OWLET_BACKEND=cpu|vulkan|hip` skips both
  unused Build-Depends **and** binary packages — use `nocpu` /
  `nouvulkan` / `nohip` with `Build-Profiles: <!nocpu>` (etc.) on each
  `Package:` stanza. Without `nocpu`, a vulkan-only build still emits an
  empty `owlet` binary package.

### `packaging/debian/rules`

Executable makefile:

```make
#!/usr/bin/make -f
export DH_VERBOSE = 1
export DEB_BUILD_MAINT_OPTIONS = hardening=+all
# OWLET_BACKEND=all|cpu|vulkan|hip

%:
	dh $@ --buildsystem=none
```

Overrides (concrete behavior, not literal final code):

1. Ensure submodule is initialized.
2. For each selected backend: `meson setup build-<backend> --prefix=/usr
   --buildtype=plain -Dgpu_backend=<backend>` (+ HIP `amd_targets`).
3. `ninja -C build-<backend>`.
4. Test on CPU build (when present): unit suite + desktop / appstream /
   schema validators.
5. `DESTDIR=$(CURDIR)/debian/owlet` (etc.) `meson install -C build-<backend>`.
6. Install license files into `/usr/share/doc/<pkg>/`.
7. Clean removes `build-cpu`, `build-vulkan`, `build-hip`.

Do **not** leave packaging-only patches in the upstream tree; keep all
Debian logic under `packaging/debian/`.

### `packaging/debian/changelog`

Initial entry with git-derived upstream version. Wrapper or a small
helper may refresh the top entry’s version before build (document how).

### `packaging/debian/copyright`

Machine-readable `Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/`:

- Owlet files: GPL-3.0-or-later (`COPYING`)
- `subprojects/transcribe.cpp/`: MIT (and note any vendored third-party
  notices upstream already documents)

### `packaging/debian/source/format`

`3.0 (native)` is acceptable for in-tree git builds that are not
uploaded to Debian yet. Switch to `3.0 (quilt)` if/when preparing a
proper Debian source upload.

### `packaging/debian/build.sh`

1. Resolve repo root (`packaging/debian/../..`).
2. Abort if repo-root `debian` already exists and is not our symlink.
3. `ln -sfn packaging/debian debian` from repo root (or equivalent).
4. `dpkg-buildpackage -b -us -uc` (binary-only; no signing for local builds).
5. Remove the symlink; leave `.deb` / `.buildinfo` / `.changes` where
   `dpkg-buildpackage` wrote them (usually parent of repo root — document
   paths clearly in README).

Optional: `OWLET_BACKEND` passthrough; `DEBIAN_FRONTEND` notes for
build-dep install.

## Docs to update (same phase)

| File | Change |
| --- | --- |
| `README.md` | Add “Build a Debian/Ubuntu package” section parallel to Arch: install `build-essential` / `devscripts` / `dpkg-dev`, install Build-Depends, `cd packaging/debian`, `OWLET_BACKEND=cpu ./build.sh`, `sudo apt install` the resulting `.deb`. Table for cpu / vulkan / hip. Short AMD ROCm repo steps for HIP. Note models are not bundled. |
| `AGENTS.md` | List phase 14 under plans status / packaging |
| `docs/plans/README.md` | Index phase 14 |

## Out of scope (first pass)

- Launchpad PPA / Open Build Service
- Uploading to Debian or Ubuntu archives
- Packaging Whisper / other models
- Non-amd64 architectures
- Flatpak / Snap (project remains system-builds-only)

> **Revised:** GitHub Actions attaching `.deb` artifacts on `v*` tags is
> in scope (extends `.github/workflows/release.yml` alongside Arch).

## Implementation order

1. Add `packaging/debian/{control,rules,changelog,copyright,source/format,build.sh}`.
2. Wire multi-backend meson configure / build / install / conflicts /
   licenses; honor `OWLET_BACKEND`.
3. Resolve and document exact package names on Ubuntu 26.04; note Debian
   sid diffs if any. Document libadwaita ≥ 1.8 requirement (Ubuntu
   24.04 / Debian 13 unsupported).
4. Document AMD ROCm apt setup for `owlet-hip` Build-Depends and Depends
   (noble suite pin on 26.04 / sid).
5. Update `README.md`, this plan’s checklist results, `AGENTS.md`,
   `docs/plans/README.md`.
6. Smoke-test CPU `.deb` on Ubuntu 26.04; Vulkan when deps available;
   HIP with AMD noble repo when available.
7. Extend `.github/workflows/release.yml` to build and attach `.deb`
   artifacts for cpu / vulkan / hip (Ubuntu 26.04 container), parallel
   to Arch.

## Verification checklist

1. [x] From a clean clone on Ubuntu 26.04: install Build-Depends for CPU,
   `cd packaging/debian && OWLET_BACKEND=cpu ./build.sh` (via
   `smoke-docker.sh cpu` → `owlet_*.deb` ~1.2MB).
2. [x] Confirm submodule was initialized and the build used
   `subprojects/transcribe.cpp` (no system `transcribe_dir`).
3. [ ] `sudo apt install` the CPU `.deb`; launch Owlet; confirm schemas /
   desktop entry / icons work after install (and after remove/reinstall).
   *(deferred — host is Arch; package metadata/contents verified from
   the artifact)*
4. [x] Repeat for `vulkan`; confirm Conflicts/Provides vs CPU
   (`owlet-vulkan_*.deb` ~7.2MB).
5. [x] With AMD ROCm repo configured (noble suite pin): build `hip`;
   artifact `owlet-hip_*.deb` ~20MB; Depends include
   `rocm-hip-runtime | hip-runtime-amd`, `hipblas`, `rocblas`. Binary is
   a multi-arch HIP fat binary (~285MB installed). `dh_shlibdeps`
   uses `-l/opt/rocm/lib --ignore-missing-info`.
6. [x] Spot-check Build-Depends / Depends names against Ubuntu 26.04
   smoke (Debian sid targeted; same libadwaita ≥ 1.8 / ROCm noble pin).
7. [x] Unit + metadata tests ran during the package build for the CPU
   backend.
8. [x] Tag release workflow builds and attaches `owlet*.deb` for cpu /
   vulkan / hip alongside Arch packages (`.github/workflows/release.yml`
   invokes `smoke-docker-inner.sh` on `ubuntu:26.04`).
