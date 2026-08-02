# Owlet

Speech-to-text GNOME app built with GTK4 + libadwaita in Vala. Uses
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for
local inference (HIP / Vulkan / CPU) and supports OpenAI-compatible
remote transcription APIs.

## Build an Arch Linux package

These steps create an installable package on Arch Linux or an
Arch-based distribution. No programming tools need to be configured by
hand; `makepkg` installs the required build dependencies.

1. Install Arch's package-building tools:

   ```bash
   sudo pacman -S --needed base-devel git
   ```

2. Download Owlet and enter its directory:

   ```bash
   git clone https://github.com/papodaca/owlet.git
   cd owlet
   ```

3. Enter the packaging directory, then build and install **one**
   variant. `makepkg` initializes the `transcribe.cpp` submodule and
   statically links it into the app. The other variants and their GPU
   dependencies will not be built or installed.

   ```bash
   cd packaging/arch
   ```

   | Variant | Recommended for | Build and install command |
   | --- | --- | --- |
   | CPU | Any computer; slowest but most compatible | `OWLET_BACKEND=cpu makepkg -si` |
   | Vulkan | Most AMD, Intel, and NVIDIA GPUs | `OWLET_BACKEND=vulkan makepkg -si` |
   | HIP | AMD GPUs with ROCm support | `OWLET_BACKEND=hip makepkg -si` |

   The variants conflict with each other because GPU support is compiled
   into Owlet. Installing another variant with `makepkg -si` will offer to
   replace the currently installed one.

After installation, launch **Owlet** from the application menu. Speech
models are downloaded from Owlet's Preferences window and are not bundled
in the package.

To update later, run `git pull` in the `owlet` directory and repeat
step 3. The generated package version includes the current Git revision,
so it changes automatically when the project is updated.

## Build a Debian / Ubuntu package

These steps create installable `.deb` packages on **Ubuntu 26.04
(resolute)** or **Debian sid**. Owlet needs **libadwaita ≥ 1.8**
(`Adw.ShortcutsDialog`), so Ubuntu 24.04 / Debian 13 are not supported
build hosts. Package names below match Ubuntu 26.04; Debian sid uses
the same names for the Owlet build/runtime deps checked so far.

1. Install packaging tools and (for the CPU variant) build dependencies:

   ```bash
   sudo apt install build-essential debhelper devscripts dpkg-dev git \
     meson ninja-build valac pkg-config cmake python3-pytest \
     appstream desktop-file-utils libglib2.0-bin \
     libgtk-4-dev libadwaita-1-dev \
     libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
     libsoup-3.0-dev libsecret-1-dev libjson-glib-dev libei-dev \
     libx11-dev libxext-dev libxrandr-dev libcairo2-dev libpango1.0-dev libblas-dev
   ```

   Vulkan additionally needs `libvulkan-dev`, `glslc`, and
   `spirv-headers` (ggml-vulkan's CMake `find_package(SPIRV-Headers)`).
   HIP needs AMD's ROCm apt repository (see below) plus `hip-dev`,
   `rocm-device-libs`, `hipblas`, `hipblas-dev`, `rocblas`,
   `rocblas-dev`, `rocminfo`, `rccl`, and noble's `libxml2` (for
   ROCm `lld`'s `libxml2.so.2`).

2. Clone Owlet and enter the Debian packaging directory:

   ```bash
   git clone https://github.com/papodaca/owlet.git
   cd owlet/packaging/debian
   ```

3. Build **one** variant. `build.sh` symlinks `packaging/debian` to the
   repo-root `debian/` directory, refreshes the changelog version from
   git, initializes the `transcribe.cpp` submodule, and runs
   `dpkg-buildpackage`. Finished `.deb` files are left in
   `packaging/debian/`.

   | Variant | Recommended for | Build command | Install |
   | --- | --- | --- | --- |
   | CPU | Any computer; slowest but most compatible | `OWLET_BACKEND=cpu ./build.sh` | `sudo apt install ./owlet_*.deb` |
   | Vulkan | Most AMD, Intel, and NVIDIA GPUs | `OWLET_BACKEND=vulkan ./build.sh` | `sudo apt install ./owlet-vulkan_*.deb` |
   | HIP | AMD GPUs with ROCm support | `OWLET_BACKEND=hip ./build.sh` | `sudo apt install ./owlet-hip_*.deb` |

   The variants conflict with each other because GPU support is compiled
   into Owlet. Install only one. Dictation prefers libei when the build
   host has **libei ≥ 1.6** (`EI_DEVICE_CAP_TEXT`); Ubuntu 26.04 / Debian
   sid currently ship 1.5, so packages fall back to `ydotool` / `xdotool`
   (`Suggests`). Runtime `libei1` is a `Recommends`, not a hard Depends.

### HIP: enable AMD ROCm apt

Distro-universe ROCm packages are too old/incomplete for the HIP
targets Owlet builds (`gfx1100;gfx1030;gfx906;gfx90a;gfx1200;gfx1201`).
Use AMD's repo (example for ROCm 6.4.3; check current AMD docs for the
latest path). AMD currently publishes **jammy** / **noble** suites only
— on Ubuntu 26.04 or Debian sid, pin the **noble** suite until a newer
one appears:

```bash
sudo mkdir -p /etc/apt/keyrings
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key \
  | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg >/dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.4.3 noble main" \
  | sudo tee /etc/apt/sources.list.d/rocm.list
printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' \
  | sudo tee /etc/apt/preferences.d/rocm-pin-600
# ROCm lld needs libxml2.so.2; Ubuntu 26.04 / sid only ship libxml2.so.16.
echo "deb http://archive.ubuntu.com/ubuntu noble main" \
  | sudo tee /etc/apt/sources.list.d/noble-rocm-compat.list
printf 'Package: libxml2 libicu74\nPin: release n=noble\nPin-Priority: 700\n' \
  | sudo tee /etc/apt/preferences.d/noble-rocm-compat
sudo apt update
sudo apt install hip-dev rocm-device-libs \
  hipblas hipblas-dev rocblas rocblas-dev rocminfo rccl \
  libxml2
```

`rocm-device-libs` is only a Recommends of `rocm-llvm`; install it
explicitly (or omit `--no-install-recommends`) so the HIP compiler can
find the ROCm device library. `libxml2` here is noble's package
(`libxml2.so.2` + `libicu74`); it coexists with distro `libxml2-16`.

Ensure `/opt/rocm/bin` is on `PATH` during the package build (the
packaging rules prepend it). If your ROCm is older than 6.4, drop
`gfx1200` / `gfx1201` from `amd_targets` in `packaging/debian/rules`.

After installation, launch **Owlet** from the application menu. Speech
models are downloaded from Preferences and are not bundled in the
package.

## Build an AppImage

These steps create a portable `*.AppImage` on **Ubuntu 26.04** (or an
equivalent glibc). Owlet needs **libadwaita ≥ 1.8**, so the AppImage
glibc floor matches that build host — it will **not** run on older
distros (e.g. Ubuntu 22.04 / 24.04). Only **CPU** and **Vulkan**
AppImages are shipped; HIP/ROCm remains Arch / Debian only.

Easiest path (Docker, mirrors CI):

```bash
git clone https://github.com/papodaca/owlet.git
cd owlet/packaging/appimage
./smoke-docker.sh cpu      # → Owlet-*-x86_64-cpu.AppImage
./smoke-docker.sh vulkan   # → Owlet-*-x86_64-vulkan.AppImage
```

Native build on Ubuntu 26.04 (install the same build deps as the Debian
section, plus `gstreamer1.0-plugins-good`, `gstreamer1.0-pulseaudio`,
`file`, `patchelf`, and for Vulkan `libvulkan-dev` / `glslc` /
`spirv-headers`):

```bash
cd packaging/appimage
OWLET_BACKEND=cpu ./build.sh
OWLET_BACKEND=vulkan ./build.sh
```

| Variant | Recommended for | Artifact |
| --- | --- | --- |
| CPU | Any computer; slowest but most compatible | `Owlet-*-x86_64-cpu.AppImage` |
| Vulkan | Most AMD, Intel, and NVIDIA GPUs | `Owlet-*-x86_64-vulkan.AppImage` |

Make the AppImage executable and run it (`chmod +x` then double-click or
`./Owlet-….AppImage`). Vulkan builds expect a **host Vulkan ICD** (GPU
drivers / Mesa); those libraries are not bundled. Speech models are
downloaded from Preferences into `$XDG_DATA_HOME/owlet/models/` and are
not bundled.

## Build & run from source

```bash
git submodule update --init --recursive
meson setup build                 # once (or -Dgpu_backend=cpu)
ninja -C build run                # build + compile schemas + launch
```

`ninja -C build` alone still builds the binary and compiles schemas into
`build/data/` for manual runs with `GSETTINGS_SCHEMA_DIR=build/data`.

Global-shortcut / tray dictation shows an always-on-top OSD that needs
X11 or XWayland (`libx11` / `libxext` / `libxrandr`). The overlay is
mirrored onto every active XRandR monitor (bottom-centered on each), so
it stays visible on dual-head even when XWayland pointer coords are
stale. Without `DISPLAY`, dictation still runs and the HUD soft-fails
with a warning.

## Tests

```bash
meson test -C build --print-errorlogs
```


Suites (see [`tests/README.md`](tests/README.md)):

| Suite | What |
| --- | --- |
| *(default metadata)* | desktop / schema / appstream validators |
| `unit` | GSettings, WAV sample, gresource paths |
| `integration` | libsecret, multipart contract, mock download + remote API |
| `ui` | Xvfb launch + preferences smoke (needs `xvfb-run`, `xdotool`) |
| `network` | HuggingFace catalog HEAD checks (opt-in / outbound) |

```bash
meson test -C build --suite unit
meson test -C build --suite integration
meson test -C build --suite ui
meson test -C build --suite network
```

Extra host packages for UI / secret tests are listed in `tests/README.md`.
Manual recipes that remain human-only (live rebind, real mic, etc.) are in
[`docs/testing.md`](docs/testing.md).

## Translations

Owlet uses GNU gettext via Meson's `i18n` module (`po/`). English is the
source language; other locales are contributed later.

- **UI files** (`.ui`): mark user-visible properties with
  `translatable="yes"`.
- **Vala**: wrap user-facing strings with `_("…")`, `C_("ctx", "…")`, or
  `ngettext` when needed.
- **Never** use `_(@"$x")` — Vala interpolates before gettext, so the
  msgid is unstable. Use `_("%s").printf (x)` instead.
- After changing strings, regenerate the template from the build dir:

  ```bash
  ninja -C build owlet-pot
  # when locales exist:
  ninja -C build owlet-update-po
  ```

- **Adding a language**: append the locale code to `po/LINGUAS`, run
  `ninja -C build owlet-update-po`, translate `po/xx.po`, and commit.
- **Testing a locale**: install to a prefix or use `meson devenv -C build`
  so `LOCALEDIR` resolves, then run with `LANGUAGE=xx ./src/owlet`.