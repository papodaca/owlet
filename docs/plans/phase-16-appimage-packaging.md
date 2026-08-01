# Phase 16 — AppImage packaging (CPU + Vulkan)

> **Status:** planned (not implemented)

## Goal

Ship in-tree AppImage packaging so a Docker/CI build can produce portable
`*.AppImage` binaries for Owlet, with GPU-backend split artifacts for
**CPU** and **Vulkan** only. `transcribe.cpp` remains built from the
bundled git submodule and statically linked (same as Arch / Debian).
Attach both AppImages to GitHub Releases alongside existing
`.pkg.tar.zst` / `.deb` artifacts.

## Motivation

Owlet is system-builds-only (no Flatpak). Arch and Debian packages cover
distro installs; AppImage covers users who want a download-and-run
binary without `makepkg` / `dpkg`. The GPU backend is baked into the
binary at compile time (static ggml archives), so one AppImage cannot
serve both CPU and Vulkan — two artifacts are required.

HIP/ROCm is intentionally **out of scope** for AppImage: bundling or
depending on `/opt/rocm` is large and fragile. Arch and Debian continue
to ship `owlet-hip`; AppImage does not.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Location | In-tree under `packaging/appimage/` (mirror `packaging/arch/` / `packaging/debian/`) |
| Backends | `cpu` \| `vulkan` **only** — reject `hip`, `all`, and any other value |
| Tooling | `linuxdeploy` + `linuxdeploy-plugin-gtk` (`DEPLOY_GTK_VERSION=4`) + `linuxdeploy-plugin-gstreamer` |
| Build host | `ubuntu:26.04` Docker (same floor as Debian packaging; libadwaita ≥ 1.8) |
| Portability | Document **Ubuntu 26.04+ / equivalent glibc** floor — do **not** promise older distros |
| Install into AppDir | `meson setup -Dgpu_backend=…` → ninja → `DESTDIR=AppDir meson install --prefix=/usr` |
| Artifact names | `Owlet-$VERSION-x86_64-cpu.AppImage` / `Owlet-$VERSION-x86_64-vulkan.AppImage` |
| Version | Git-derived, same spirit as Arch `pkgver()` / Debian `owlet_deb_version()` (tag `vX.Y.Z` → `X.Y.Z`; else `0.1.0+git<rN>.<short-hash>`) |
| Binary name | Remains `owlet` inside the AppDir (backend is in the **AppImage filename**, not the executable name) |
| Desktop / icons / schemas | Come from meson install into AppDir (`im.apodaca.owlet.desktop`, icons, gschema) |
| Vulkan runtime | Bundle app + linked userspace libs; **do not** ship Mesa / GPU ICDs / EGL / drm driver bits — host `libvulkan` + ICD |
| GStreamer | Bundle a **minimal** audio set (`pulsesrc` / Pulse compat, `audioconvert`, `audioresample`, `app`, coreelements); avoid full “bad” plugin set; do not mix host GST plugins with bundled core |
| Wayland | After gtk plugin: neutralize forced `GDK_BACKEND=x11` if the plugin injects it |
| Models | Not bundled — downloaded at runtime to `$XDG_DATA_HOME/owlet/models/` |
| Test helpers | `download_cli` / `remote_cli` stay `install: false` — not packaged |
| Local + CI HIP | No HIP AppImage path at all (local `build.sh` fails fast; CI matrix never includes hip) |
| Arch / Debian release CI | **Unchanged** — still `cpu` / `vulkan` / `hip` |
| AppImage release CI | Matrix `backend: [cpu, vulkan]` only |
| FUSE on CI | `APPIMAGE_EXTRACT_AND_RUN=1` (GitHub runners typically lack FUSE) |

## Current build facts (shared with phases 12 / 14)

Trust [`phase-12-packaging.md`](phase-12-packaging.md) / [`phase-14-debian-packaging.md`](phase-14-debian-packaging.md)
and `AGENTS.md` for meson install layout and deps. Summary for AppImage:

### Installed into AppDir (`meson install --prefix=/usr`)

| Path | Source |
| --- | --- |
| `AppDir/usr/bin/owlet` | `src/meson.build` executable |
| `AppDir/usr/bin/owlet-signal` | `data/owlet-signal.sh` |
| `AppDir/usr/share/applications/im.apodaca.owlet.desktop` | merged from `.in` |
| `AppDir/usr/share/metainfo/im.apodaca.owlet.metainfo.xml` | merged from `.in` |
| `AppDir/usr/share/glib-2.0/schemas/im.apodaca.owlet.gschema.xml` | `data/` |
| `AppDir/usr/share/dbus-1/services/im.apodaca.owlet.service` | configured from `.in` |
| `AppDir/usr/share/icons/hicolor/…/im.apodaca.owlet*.svg` | icons |

linuxdeploy then bundles shared library deps (GTK4, libadwaita, GStreamer,
soup, secret, json-glib, X11, BLAS, etc.) into the AppDir and produces
the final AppImage. ggml / transcribe remain **static** inside `owlet`.

### Shared vs host

| Component | AppImage strategy |
| --- | --- |
| `libtranscribe.a` / `libggml*.a` | Already static in `owlet` |
| GTK4 / libadwaita / GLib / GST core | Bundled via linuxdeploy + plugins |
| GStreamer Pulse (and optional PipeWire) plugins | Bundled curated set via gstreamer plugin |
| `libvulkan.so.1` + ICDs | Prefer **host** loader/ICD; exclude Mesa/driver libs from the image |
| ROCm / HIP | N/A — no HIP AppImage |

### glibc reality

Building on Ubuntu 26.04 for libadwaita ≥ 1.8 sets a hard glibc floor.
An AppImage built there will **not** run on older glibc hosts (e.g.
Ubuntu 22.04 / 24.04). Document this in README and the GitHub Release
body. Do not attempt full-glibc bundling or Adwaita backports in this
phase.

## Layout

```
packaging/appimage/
  build.sh                 # OWLET_BACKEND=cpu|vulkan → AppDir → AppImage
  smoke-docker.sh          # host → ubuntu:26.04 + BACKEND
  smoke-docker-inner.sh    # apt deps + ./build.sh (release.yml mirrors this)
  # ephemeral (gitignored): AppDir/, *.AppImage, linuxdeploy downloads
```

Orchestration: extend `packaging/build.sh` so
`./build.sh appimage [cpu|vulkan|all]` works; when `all` (or top-level
`./build.sh all`), AppImage backends are **only** `cpu` then `vulkan`
(never hip). Arch/Debian `all` paths keep hip.

## Implementation details

### `packaging/appimage/build.sh`

1. Resolve repo root (`packaging/appimage/../..`).
2. Require `OWLET_BACKEND` ∈ `{cpu,vulkan}`; exit nonzero with a clear
   message for `hip` / `all` / anything else.
3. `git submodule update --init --recursive` (same as other packaging).
4. Derive `VERSION` from git (tag or `0.1.0+git…`).
5. Clean prior `AppDir/` and matching `Owlet-*-x86_64-${OWLET_BACKEND}.AppImage`
   for this backend.
6. `meson setup` with `-Dgpu_backend=$OWLET_BACKEND` (no `-Dtranscribe_dir`),
   `ninja`, `DESTDIR=$PWD/AppDir meson install --prefix=/usr`.
7. Fetch pinned `linuxdeploy-x86_64.AppImage` + gtk / gstreamer plugin
   scripts into a cache dir under `packaging/appimage/` (or `/tmp` in CI);
   `chmod +x`. Prefer pinned release URLs over floating `continuous` when
   practical.
8. Run linuxdeploy with `DEPLOY_GTK_VERSION=4`, `--plugin gtk`,
   `--plugin gstreamer`, `--appdir AppDir`, `--output appimage`,
   `VERSION=…`, and `OUTPUT=Owlet-$VERSION-x86_64-$OWLET_BACKEND.AppImage`
   (or rename after). Set `APPIMAGE_EXTRACT_AND_RUN=1`.
9. Post-process AppRun hooks if the gtk plugin forces `GDK_BACKEND=x11`
   — remove or override so Wayland works.
10. For Vulkan builds: ensure graphics driver / ICD / EGL / drm libs are
    on the exclude path (strip if accidentally deployed). Document host
    Vulkan ICD requirement in README.
11. Write the final `.AppImage` into `packaging/appimage/`.

Optional smoke inside `build.sh` (or smoke-inner only):

- `./Owlet-…AppImage --appimage-extract-and-run --help` (or equivalent)
  under Xvfb when available.
- After extract: `gst-inspect-1.0` against bundled `pulsesrc` with
  `GST_PLUGIN_SYSTEM_PATH_1_0` pointed at the AppDir tree.

### `packaging/appimage/smoke-docker.sh` / `smoke-docker-inner.sh`

Mirror Debian:

- Outer: `BACKEND=${1:?cpu|vulkan}`, `docker run … ubuntu:26.04` → inner.
- Inner: `apt-get` install build deps (CPU list from
  `packaging/debian/smoke-docker-inner.sh`, plus Vulkan packages when
  `BACKEND=vulkan`: `libvulkan-dev`, `glslc`, `spirv-headers`), runtime
  GStreamer plugins needed for bundling (`gstreamer1.0-plugins-good`,
  and PipeWire plugin package if we ship `pipewiresrc`), plus tools to
  download/run linuxdeploy (`curl` / `wget`, `file`, `desktop-file-utils`,
  etc.). **No ROCm / HIP packages.**
- Create `builder` user; `chown` + EXIT trap restore host uid/gid on the
  bind mount (same pattern as arch/debian smoke-inner).
- `cd /workspace/packaging/appimage && sudo -u builder env OWLET_BACKEND=$BACKEND ./build.sh`.

### Extend `packaging/build.sh`

| Touch point | Change |
| --- | --- |
| `usage` | Document `appimage` and backends `cpu\|vulkan\|all` (no hip) |
| Distro case | Accept `appimage`; `all` top-level includes appimage after debian |
| `pkg_dir_for` | `appimage` → `packaging/appimage` |
| `expected_pkgs_for` | `Owlet-*-x86_64-cpu.AppImage` / `…-vulkan.AppImage` |
| `forbidden_pkgs_for` | Cross-backend leftover warnings |
| `clean_backend_artifacts` | Remove matching AppImage(s) before rebuild |
| `inspect_pkg` | Optional: `file` / `--appimage-help` if available |
| `run_distro` for appimage `all` | Loop `cpu vulkan` **only** |
| `list_artifacts` | List `*.AppImage` |

### Extend `.github/workflows/release.yml`

1. Add job `appimage` (name `AppImage (${{ matrix.backend }})`):
   - `matrix.backend: [cpu, vulkan]` — **no hip**.
   - Checkout with submodules + `fetch-depth: 0`.
   - `docker run … ubuntu:26.04` → `packaging/appimage/smoke-docker-inner.sh`
     with `BACKEND`.
   - Upload artifact `appimage-${{ matrix.backend }}` from
     `packaging/appimage/*.AppImage` (`if-no-files-found: error`).
2. `publish.needs`: add `appimage` alongside `arch` and `debian`.
3. Download pattern: include `appimage-*`.
4. Release `files:` include `dist/*.AppImage`.
5. Release body: new “AppImage” section — CPU + Vulkan only; note
   Ubuntu 26.04+ / glibc floor; note HIP remains Arch/Debian only;
   models not bundled.

Do **not** change Arch or Debian matrix backends.

### Docs / ignore

| File | Change |
| --- | --- |
| `README.md` | Add “Build an AppImage” section: Docker or native Ubuntu 26.04, `cd packaging/appimage`, `OWLET_BACKEND=cpu ./build.sh` (and vulkan). Table CPU / Vulkan only. State glibc floor. Note HIP is Arch/Debian only. Models not bundled. |
| `AGENTS.md` | Packaging line + plans status: phase 16 AppImage (CPU/Vulkan) |
| `docs/plans/README.md` | Index phase 16 |
| `.gitignore` | `/packaging/appimage/*.AppImage`, `/packaging/appimage/AppDir/`, linuxdeploy download cache if kept in-tree |

## Out of scope

- HIP / ROCm AppImage (local or CI)
- Dropping HIP from Arch / Debian release jobs
- Flatpak / Snap
- Guaranteeing runs on Ubuntu 24.04 or older
- Non-x86_64 architectures
- Bundling Whisper / other models
- Launchpad / OBS / AUR publication changes

## Implementation order

1. Add `packaging/appimage/{build.sh,smoke-docker.sh,smoke-docker-inner.sh}`.
2. Wire meson → AppDir → linuxdeploy (GTK4 + GStreamer); CPU first.
3. Vulkan path + exclude graphics driver libs; document host ICD.
4. Extend `packaging/build.sh` for `appimage` (cpu/vulkan only).
5. Update `.gitignore`, `README.md`, `AGENTS.md`, `docs/plans/README.md`.
6. Smoke-test via `./smoke-docker.sh cpu` then `vulkan` on `ubuntu:26.04`.
7. Extend `.github/workflows/release.yml` AppImage job + publish attachments.

## Verification checklist

1. [ ] `packaging/appimage/smoke-docker.sh cpu` produces
   `Owlet-*-x86_64-cpu.AppImage`.
2. [ ] Same for `vulkan` → `Owlet-*-x86_64-vulkan.AppImage`.
3. [ ] `OWLET_BACKEND=hip ./build.sh` (and `all`) fail fast with a clear
   error; no AppImage emitted.
4. [ ] `./packaging/build.sh appimage` runs cpu then vulkan only.
5. [ ] Extract-and-run smoke: AppImage starts / prints help under Xvfb on
   the build image; bundled `pulsesrc` visible to `gst-inspect` when
   probed against the AppDir.
6. [ ] Vulkan AppImage does not bundle Mesa ICD / driver libs; README
   states host Vulkan ICD requirement.
7. [ ] `release.yml` on `v*` builds/uploads AppImages for cpu + vulkan;
   Arch/Debian hip jobs unchanged; release notes mention AppImage +
   glibc floor.
8. [ ] README documents AppImage build/run and 26.04+ floor.
