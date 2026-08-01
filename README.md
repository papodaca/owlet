# kaki

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

2. Download Kaki and enter its directory:

   ```bash
   git clone https://github.com/papodaca/kaki.git
   cd kaki
   ```

3. Build and install the `transcribe.cpp` source package required by
   Kaki:

   ```bash
   cd packaging/arch-transcribe-cpp
   makepkg -si
   ```

4. Enter the Kaki packaging directory, then build and install **one**
   variant. The other variants and their GPU dependencies will not be
   built or installed.

   ```bash
   cd ../arch
   ```

   | Variant | Recommended for | Build and install command |
   | --- | --- | --- |
   | CPU | Any computer; slowest but most compatible | `KAKI_BACKEND=cpu makepkg -si` |
   | Vulkan | Most AMD, Intel, and NVIDIA GPUs | `KAKI_BACKEND=vulkan makepkg -si` |
   | HIP | AMD GPUs with ROCm support | `KAKI_BACKEND=hip makepkg -si` |

   The variants conflict with each other because GPU support is compiled
   into Kaki. Installing another variant with `makepkg -si` will offer to
   replace the currently installed one.

After installation, launch **Kaki** from the application menu. Speech
models are downloaded from Kaki's Preferences window and are not bundled
in the package.

To update later, run `git pull` in the `kaki` directory and repeat steps
3–4. The generated package version includes the current Git revision, so
it changes automatically when the project is updated.

## Build & run from source

```bash
git submodule update --init --recursive
meson setup build                 # once (or -Dgpu_backend=cpu)
ninja -C build run                # build + compile schemas + launch
```

`ninja -C build` alone still builds the binary and compiles schemas into
`build/data/` for manual runs with `GSETTINGS_SCHEMA_DIR=build/data`.

Global-shortcut / tray dictation shows an always-on-top OSD that needs
X11 or XWayland (`libx11` / `libxext`). Without `DISPLAY`, dictation still
runs and the HUD soft-fails with a warning.

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

Kaki uses GNU gettext via Meson's `i18n` module (`po/`). English is the
source language; other locales are contributed later.

- **UI files** (`.ui`): mark user-visible properties with
  `translatable="yes"`.
- **Vala**: wrap user-facing strings with `_("…")`, `C_("ctx", "…")`, or
  `ngettext` when needed.
- **Never** use `_(@"$x")` — Vala interpolates before gettext, so the
  msgid is unstable. Use `_("%s").printf (x)` instead.
- After changing strings, regenerate the template from the build dir:

  ```bash
  ninja -C build kaki-pot
  # when locales exist:
  ninja -C build kaki-update-po
  ```

- **Adding a language**: append the locale code to `po/LINGUAS`, run
  `ninja -C build kaki-update-po`, translate `po/xx.po`, and commit.
- **Testing a locale**: install to a prefix or use `meson devenv -C build`
  so `LOCALEDIR` resolves, then run with `LANGUAGE=xx ./src/kaki`.