# Kaki — agent notes

GTK4 + libadwaita speech-to-text app in **Vala**. Local inference via
git submodule `subprojects/transcribe.cpp` (static link); optional
OpenAI-compatible remote backend. In-app transcript **and** keystroke
dictation. System builds only (no Flatpak). GPL-3.0-or-later.

Product scope & phase plans: `docs/plans/README.md` (trust code over
that file when they disagree — see stale notes below).

## Feature worktrees (Worktrunk)

Start every feature on its own worktree with [Worktrunk](https://worktrunk.dev)
(`wt`). Do **not** use raw `git worktree add` / in-place branch switching for
feature work.

User config puts worktrees at `.worktrees/<branch>/` (see
`~/.config/worktrunk/config.toml`). Shell integration is optional; prefer
`--no-cd` and `cd` yourself so agent shells work without it:

```bash
# from the main repo checkout
wt switch --create <branch> --no-cd --format json -y
# → {"path":".../Kaki/.worktrees/<branch>", ...}
cd .worktrees/<branch>

git submodule update --init --recursive   # worktrees do NOT inherit the checkout
meson setup build                         # build/ is per-worktree; cold start
ninja -C build run                        # build + schemas + launch
```

Useful:

```bash
wt switch <branch> --no-cd                # existing branch → create/select worktree
wt switch --create <branch> --base=@      # branch from current HEAD
wt list                                   # status across worktrees
wt remove                                 # drop current worktree (+ merged branch)
wt switch -x <cmd> …                      # run a tool after switch (needs shell cd)
```

## Commands

```bash
git submodule update --init --recursive   # required once (and in every new worktree)
meson setup build                         # once; gpu_backend=auto (HIP→Vulkan→CPU)
ninja -C build run                        # build + compile schemas + launch
meson test -C build --print-errorlogs     # metadata + pytest suites
meson test -C build --suite unit          # no Xvfb / keyring required
```

Force backend:

```bash
meson setup build -Dgpu_backend=hip -Damd_targets=gfx1100
meson setup build -Dgpu_backend=vulkan
meson setup build -Dgpu_backend=cpu
meson setup --reconfigure build …         # change options on existing builddir
```

Uninstalled GSettings: `ninja -C build` compiles schemas into `build/data/`
(via `data/meson.build`); `ninja -C build run` sets `GSETTINGS_SCHEMA_DIR`
for you. Manual equivalent:

```bash
GSETTINGS_SCHEMA_DIR=build/data ./build/src/kaki
```

Automated suites + manual gap list: `docs/testing.md` / `tests/README.md`.

## Architecture agents miss

- **transcribe.cpp is not a meson `cmake.subproject()`**. Root
  `meson.build` drives cmake via `custom_target` + `declare_dependency`
  because meson's cmake wrapper breaks Vulkan (`;;;` config) and HIP
  (demands nvcc). Plans still say A1/`cmake.subproject()` — ignore that.
- **HIP**: sidecar cmake gets `PATH` prepended with ROCm's `bin/` (often
  `/opt/rocm/bin`) so `enable_language(HIP)` finds clang; the user shell
  is left alone. Empty `-Damd_targets=` autodetects via `rocminfo`.
- **Audio capture** (`recorder.vala`): GStreamer
  `pulsesrc` → else `pipewiresrc` → `audioconvert` → `audioresample` →
  caps (16 kHz mono F32LE) → `appsink`.
- **Hand-written VAPIs** in `src/vapi/` (`transcribe.vapi`,
  `libei-1.0.vapi` + C shims). They bind only the subset Kaki uses —
  extend the VAPI when calling new C API, do not regenerate from headers.
- **`Config.GPU_BACKEND`** is compile-time (from meson option →
  `config.h` / `src/config.vapi`), not the runtime GSettings
  `gpu-backend` key.
- **gresource aliases**: `src/ui/preferences.ui` and
  `src/ui/test-sample.wav` are exposed as `/org/kaki/app/preferences.ui`
  and `…/test-sample.wav` (no `ui/` segment). `[GtkTemplate]` paths must
  match the alias; see `src/kaki.gresource.xml`.
- **Dictation keystrokes**: libei → ydotool → xdotool (`HAVE_LIBEI`
  optional compile-in; overridable in settings).
- **Global shortcuts**: xdg-desktop-portal `GlobalShortcuts`, with
  `data/kaki-signal.sh` (installed as `kaki-signal`) as the
  portal-less fallback.
- **Close-to-tray**: hand-rolled StatusNotifierItem + DBusMenu over
  GIO (`src/services/tray.vala`) — no ayatana dep. Pref
  `close-to-tray` hides (does not destroy) the window on close so
  global shortcuts keep working. Idle tray icon
  `org.kaki.app-symbolic`; while the mic is recording, swaps to
  `org.kaki.app-recording-symbolic` (record-light badge). Icons
  install via meson to `$datadir/icons/hicolor/…`; hosts resolve
  IconName from the installed theme (no gresource / IconPixmap
  fallback, so icons require an installed build). App / desktop
  icon remains `org.kaki.app`. GNOME Shell needs an AppIndicator /
  KStatusNotifierItem extension for the icon to appear.
- **libsecret schema** is `org.kaki.app` with attribute `type=api-key`
  (plans README saying schema name `kaki` is stale).
- Models live under `$XDG_DATA_HOME/kaki/models/` (typically
  `~/.local/share/kaki/models/`); Preferences opens that dir via
  `Gtk.FileLauncher`. Download catalog is Whisper Tiny/Base/Small `.en`
  Q8_0 GGUFs only for now.
- App id / resource base: `org.kaki.app` / `/org/kaki/app`.

Transcription backends implement `Kaki.TranscriptionSource`
(`local-source.vala` / `remote-openai-source.vala`), selected by
GSettings `transcription-source`. PCM contract at that boundary:
F32LE / 16 kHz / mono.

## Dependencies

pkg-config: `gtk4`, `libadwaita-1 >= 1.4`, `gstreamer-1.0`,
`gstreamer-base-1.0`, `gstreamer-app-1.0`, `gstreamer-audio-1.0`,
`libsecret-1`, `libsoup-3.0`, `json-glib-1.0`, plus optional
`libei-1.0`. Runtime optional: `rocminfo`, `ydotool`, `xdotool`,
`xdg-desktop-portal`. C++ toolchain required to link the transcribe
static lib. Submodule must be initialized.

## Plans status

Phases 0–7 and 11 are in tree (Phase 7 = pytest suites under `meson test`;
Phase 11 = recording start/stop tones + Preferences disable). Still open
(see `docs/plans/`):

| # | Goal |
| --- | --- |
| 8 | Expand `shortcuts-dialog.ui` to match Preferences (+ Copy / Clear) — dialog is still Quit/Show Shortcuts only |
| 9 | Finish gettext/`po/` (`kaki.pot` not committed yet; `LINGUAS` empty) |
| 10 | Close-to-tray (GIO SNI) + recording tray icon — see `docs/plans/phase-10-close-to-tray.md` |
| 12 | Arch packaging (PKGBUILD split CPU/Vulkan/HIP; static submodule link) — see `docs/plans/phase-12-packaging.md` |
| 14 | Debian/Ubuntu packaging (`.deb` split CPU/Vulkan/HIP; static submodule link) — see `docs/plans/phase-14-debian-packaging.md` |

## Layout

| Path | Role |
| --- | --- |
| `src/*.vala`, `src/ui/` | App + preferences UI |
| `src/services/` | Recorder, local/remote transcription, keystroke, secrets, shortcuts, downloads, tray (SNI) |
| `src/vapi/` | Hand-written bindings + shims |
| `data/` | Desktop/AppStream/GSettings, `kaki-signal` helper |
| `docs/plans/` | Phase plans — **may lag the code**; trust `meson.build` / `src/` |
| `subprojects/transcribe.cpp/` | Upstream engine; its own `AGENTS.md` |

## Working in the submodule

Only when changing `subprojects/transcribe.cpp` itself: read that
tree's `AGENTS.md` (`uv run` for Python, pinned clang-format script,
C ABI exception discipline). For normal Kaki work, treat the submodule
as a pinned dependency (currently `v0.1.2`) and edit the Vala/VAPI
side instead.