# Phase 18 — Flatpak packaging (Vulkan + CPU fallback)

> **Status:** planned (not implemented)

## Goal

Ship in-tree Flatpak packaging for Owlet (`im.apodaca.owlet`) on the
GNOME runtime, producing a single sandboxed app that builds ggml with
**Vulkan** and falls back to **CPU** at runtime when no suitable GPU is
available. Provide a local/CI Flatpak bundle path and a Flathub-ready
manifest shape. HIP/ROCm stays Arch/Debian-only.

This **reintroduces** Flatpak as an optional distribution channel.
Phase 0 dropped an early scaffold manifest so the project could focus on
system builds; Arch, Debian, and AppImage remain first-class. Flatpak
does not replace them.

## Motivation

Flatpak is how many GNOME / Flathub users install desktop apps. Owlet’s
core stack (GTK4, libadwaita, GStreamer, portals, libsecret) maps cleanly
onto `org.gnome.Platform`, but dictation (global shortcuts + typing into
other apps) is sandbox-sensitive. A deliberate portal-first Flatpak plan
is required so we do not ship a Vocalinux-style `--device=all` / ydotool
manifest that Flathub will reject or that silently breaks Wayland.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| App ID | `im.apodaca.owlet` (unchanged) |
| Location | In-tree under `packaging/flatpak/` (mirror arch/debian/appimage) |
| Runtime / SDK | `org.gnome.Platform` / `org.gnome.Sdk` — pin a current stable branch that ships **libadwaita ≥ 1.8** (Owlet needs `Adw.ShortcutsDialog`) |
| Flathub artifacts | **One** app — Vulkan-enabled build with CPU fallback; **not** separate cpu/vulkan Flathub IDs |
| HIP / ROCm | **Out of scope** (no Flatpak module, no `--device=all` for KFD) |
| Build system | Manifest `modules` build Owlet with Meson (`-Dgpu_backend=vulkan`); pin `transcribe.cpp` submodule as `type: git` + **commit hash** |
| Models | Not bundled — download into sandbox `$XDG_DATA_HOME/owlet/models/` (`~/.var/app/im.apodaca.owlet/data/owlet/models/`) |
| Audio | `--socket=pulseaudio` (PipeWire Pulse compat); prefer GStreamer `pulsesrc` |
| GPU | `--device=dri` only; use runtime GL/Vulkan extensions; do **not** bundle Mesa/ICDs |
| Network | `--share=network` (model download + remote OpenAI-compatible APIs) |
| Display | `--share=ipc`, `--socket=wayland`, `--socket=fallback-x11` |
| Tray (SNI) | `--talk-name=org.kde.StatusNotifierWatcher` only — no `org.gnome.Shell`, no `--own-name` |
| Global shortcuts | `org.freedesktop.portal.GlobalShortcuts` (already used) — no extra finish-arg |
| Keystroke injection | **Portal / RemoteDesktop + libei (`ConnectToEIS`)** first; clipboard-paste fallback; **do not** rely on ydotool/`--device=all` / host `LIBEI_SOCKET` as the Flatpak default |
| Secrets | Prefer Secret portal via modern libsecret; avoid `--talk-name=org.freedesktop.secrets` unless runtime proves it necessary |
| Host filesystem | **No** `--filesystem=home` / `host` / `xdg-data` by default |
| Session bus | **No** `--socket=session-bus` |
| Binary name | `owlet` (`command: owlet`) |
| Test helpers | `download_cli` / `remote_cli` stay `install: false` |
| CI | `flatpak-builder` via Flathub GitHub Action image (`ghcr.io/flathub-infra/flatpak-github-actions:gnome-<ver>`, privileged) |
| Release artifact | Optional `.flatpak` bundle on GitHub Releases; Flathub remains the install path of record |
| Arch / Debian / AppImage | **Unchanged** (including HIP on Arch/Debian; AppImage still cpu+vulkan only) |

## Why one Flatpak (unlike Arch/Debian/AppImage)

Arch/Debian/AppImage ship **separate binaries** because ggml backends are
compile-time static archives. Flatpak/Flathub prefers **one app ID**. A
Vulkan-enabled ggml build still runs on CPU when no usable Vulkan device
exists, so one Flatpak covers both. HIP remains impossible to package
sanely inside the sandbox (no official ROCm runtime; needs `/dev/kfd`).

Do **not** publish `im.apodaca.owlet.Cpu` / `.Vulkan` duplicates on
Flathub.

## Current code gaps Flatpak must address

These are implementation prerequisites, not “manifest-only” work:

### 1. Libei today talks to a host socket

`src/services/keystroke.vala` uses `Ei.Context.setup_backend_socket()`
(host `LIBEI_SOCKET` / compositor EIS socket). That path is appropriate
for system packages; inside Flatpak it is **not** the sandboxed model.

Flatpak-capable injection should:

1. Request **RemoteDesktop** (and/or the documented EIS portal path) via
   xdg-desktop-portal.
2. Obtain an EIS connection fd (`ConnectToEIS` / equivalent).
3. Feed that fd into libei (`setup_backend_fd` / current libei API —
   extend `src/vapi/libei-1.0.vapi` + shims if needed).
4. Keep TEXT capability preference (libei ≥ 1.6) for Unicode dictation.
5. On portal denial or missing compositor support: degrade clearly
   (toast / status) and offer **clipboard + paste chord** before any
   ydotool idea.

ydotool / uinput / `--device=all` are **non-goals** for the Flatpak
default. Native packages keep the existing libei → ydotool → xdotool
chain.

### 2. Global shortcuts

Already portal-based (`src/services/global-shortcuts.vala`). Expected to
work on GNOME and KDE; document weaker support on many wlroots
compositors. `owlet-signal` remains a native/portal-less fallback and is
awkward inside the sandbox — document “use portal bind” for Flatpak
users; do not grant session-bus or host script hacks to make the helper
first-class in Flatpak.

### 3. Tray icons

SNI exports theme **icon names** (`im.apodaca.owlet-symbolic`,
`im.apodaca.owlet-recording-symbolic`). Flatpak must install those icons
in the app export so hosts resolve IconName (same constraint as native:
no IconPixmap fallback). GNOME still needs an AppIndicator/SNI
extension — document it.

### 4. Models / Preferences “open folder”

Models must land under the sandbox `XDG_DATA_HOME`. Opening the models
dir should use portals (`Gtk.FileLauncher` / OpenURI) so we do not need
`--filesystem=xdg-data`. Verify the Preferences “open models folder”
action works under Flatpak; fix if it assumes a host path outside the
sandbox export.

### 5. AppStream / metainfo quality

`data/im.apodaca.owlet.metainfo.xml.in` is still scaffold placeholder
copy. Flathub requires real summary, description, URLs, screenshot(s),
releases. Polish metainfo as part of this phase (or a tightly coupled
prerequisite commit) before submission.

## Recommended `finish-args`

```text
--share=ipc
--socket=wayland
--socket=fallback-x11
--socket=pulseaudio
--device=dri
--share=network
--talk-name=org.kde.StatusNotifierWatcher
```

### Explicitly avoid (unless forced later with justification)

| Permission | Why avoid |
| --- | --- |
| `--talk-name=org.freedesktop.portal.*` | Redundant; Flathub linter rejects |
| `--filesystem=home` / `host` / `xdg-data` | Models + config stay in sandbox XDG |
| `--socket=session-bus` | Over-broad; Flathub red flag |
| `--device=all` | ydotool/uinput/KFD trap; destroys sandbox story |
| `--filesystem=xdg-run/pipewire-0` | Only if Pulse socket proves insufficient |
| `--talk-name=org.gnome.Shell` | Over-broad (do not copy Vocalinux blindly) |
| `--talk-name=org.freedesktop.secrets` | Prefer Secret portal; add only if proven needed |

## Layout

```
packaging/flatpak/
  im.apodaca.owlet.yml     # primary flatpak-builder manifest
  build.sh                 # local: flatpak-builder → optional bundle
  smoke-docker.sh          # host → privileged Flathub/GNOME builder image
  smoke-docker-inner.sh    # install SDK/runtime + run build.sh
  # ephemeral (gitignored): .flatpak-builder/, build-dir/, repo/, *.flatpak
```

Optional later (out of band / Flathub fork): a Flathub-remote manifest
repo that points at tagged upstream sources. Keep the **canonical
manifest shape** in-tree so CI and Flathub do not diverge silently.

### Manifest sketch (locking intent, not final YAML)

- `id: im.apodaca.owlet`
- `runtime: org.gnome.Platform` / `sdk: org.gnome.Sdk` / pinned
  `runtime-version`
- `command: owlet`
- `finish-args`: list above
- `modules`:
  1. Any missing build deps not in the GNOME SDK (keep minimal —
     prefer SDK packages: GTK4, libadwaita, GStreamer, libsecret,
     libsoup, json-glib, Vulkan headers/`shaderc` as required to build
     ggml Vulkan).
  2. `owlet` Meson module:
     - sources: current directory / git tag; submodule
       `subprojects/transcribe.cpp` pinned by commit
     - `config-opts`: `-Dgpu_backend=vulkan` (and whatever else packaging
       already uses; empty `-Dtranscribe_dir=`)
     - ensure libei is available from the runtime/SDK **or** built as a
       module if TEXT (≥ 1.6) is too old on the pinned runtime

## Implementation details

### Portal-first keystroke work (code)

1. Audit `keystroke.vala` + VAPI for fd-based libei setup.
2. Add a portal EIS / RemoteDesktop client path (new small service or
   extend keystroke) gated so **native** builds can keep socket/ydotool
   fallbacks.
3. Detection order suggestion for Flatpak builds / runtime sandbox:
   `portal-libei` → clipboard paste → (optional) clear error.
   Do not auto-spawn ydotool inside the sandbox.
4. Manual test matrix: GNOME, KDE Plasma; note wlroots as best-effort.
5. Document permission prompts (RemoteDesktop / Input) the user will see
   on first dictation.

### `packaging/flatpak/build.sh`

1. Resolve repo root; `git submodule update --init --recursive`.
2. Require `flatpak`, `flatpak-builder`, and the pinned GNOME
   Platform/SDK (document `flatpak install` commands).
3. `flatpak-builder --user --force-clean --repo=repo build-dir im.apodaca.owlet.yml`
   (flags may match Flathub action defaults).
4. Optional: `flatpak build-bundle repo Owlet-$VERSION-x86_64.flatpak im.apodaca.owlet`.
5. Optional export/install to user installation for local smoke.
6. Run `flatpak-builder-lint` / AppStream validation when available.

### Docker smoke

Mirror other packaging smokes, but use the **official Flatpak builder
image** (privileged) rather than plain `ubuntu:26.04`:

- Outer: `smoke-docker.sh` → `docker run --privileged … ghcr.io/flathub-infra/flatpak-github-actions:gnome-<ver>`.
- Inner: ensure runtime/SDK, run `build.sh`, assert bundle or build-dir
  app exists.
- Cache `.flatpak-builder` where practical.

### Extend `packaging/build.sh` (optional but preferred)

| Touch point | Change |
| --- | --- |
| `usage` | Document `flatpak` (single backend / no hip matrix) |
| Distro case | Accept `flatpak`; top-level `all` may include it **after** appimage or leave opt-in only if build time is too heavy |
| Artifacts | `Owlet-*-x86_64.flatpak` (or document “repo export only”) |

If Flatpak CI time is large, it is acceptable for this phase to wire
**GitHub workflow only** and keep `./packaging/build.sh flatpak` as a
thin wrapper — but document the chosen UX.

### CI / release

1. Add workflow job `flatpak` (ci and/or release):
   - Checkout with submodules + `fetch-depth: 0`.
   - `flatpak/flatpak-github-actions/flatpak-builder` (or flathub-infra
     equivalent) with GNOME image, `manifest-path:
     packaging/flatpak/im.apodaca.owlet.yml`.
   - Cache builder dir.
   - Upload bundle artifact when producing one.
2. On `v*` tags: attach `.flatpak` next to `.pkg.tar.zst` / `.deb` /
   `.AppImage` **or** only publish to Flathub and skip GitHub bundle —
   **prefer attaching a bundle** for testing parity with other channels,
   with README stating Flathub is preferred for updates.
3. Release notes section: Flatpak = Vulkan+CPU fallback; HIP =
   Arch/Debian only; portal permissions; GNOME AppIndicator note;
   models in `~/.var/app/im.apodaca.owlet/…`.

Do **not** change Arch/Debian/AppImage matrices.

### Docs / ignore

| File | Change |
| --- | --- |
| `README.md` | “Build / install Flatpak” section: runtime/SDK pin, `packaging/flatpak/build.sh`, finish-args summary, portal dictation caveats, HIP not included |
| `AGENTS.md` | Drop blanket “no Flatpak”; note Flatpak under packaging + portal-libei caveat |
| `docs/plans/README.md` | Index phase 18; revise scope summary “No flatpak” → system builds **plus** Flatpak channel |
| `.gitignore` | `/packaging/flatpak/.flatpak-builder/`, `build-dir/`, `repo/`, `*.flatpak` |
| Metainfo | Real Flathub-facing copy + screenshot hosting |

## Feature matrix (Flatpak vs native)

| Feature | Native packages | Flatpak target |
| --- | --- | --- |
| In-app Record / transcript | Yes | Yes |
| Local Vulkan / CPU inference | Yes (split pkgs / AppImages) | Yes (one Vulkan build + CPU fallback) |
| HIP / ROCm | Arch + Debian | **No** |
| Mic capture | pulsesrc / pipewiresrc | pulsesrc via `--socket=pulseaudio` |
| Global shortcuts | Portal + `owlet-signal` | Portal primary |
| Dictation typing | libei socket → ydotool → xdotool | Portal EIS/libei → clipboard paste |
| Tray SNI | Yes (+ GNOME extension) | Same + SNI talk-name |
| API keys (libsecret) | Host keyring | Secret portal / sandboxed secret |
| Model storage | `~/.local/share/owlet/models` | `~/.var/app/im.apodaca.owlet/data/owlet/models` |
| Dictation HUD (X11 OSD) | Yes on X11/XWayland | Best-effort via fallback-x11; Wayland-native HUD remains future work |

## Major risks

1. **Flathub policy / review** — apps whose core UX is “type into other
   apps” + global hotkeys attract scrutiny. Portal-first permissions and
   honest desktop support matrix are mandatory.
2. **Portal coverage** — strong on GNOME/KDE; weak on some wlroots
   setups. Do not claim universal Wayland dictation.
3. **Injection fidelity** — portal keysyms follow layouts; Unicode often
   needs TEXT capability or clipboard paste.
4. **`--device=all` temptation** — copying ydotool Flatpaks will fight
   review and gut the sandbox. Resist.
5. **Runtime libei age** — may need a module bump for TEXT.
6. **Secret portal gaps** — some desktops still need Secrets Service
   talk-name; add only with evidence.
7. **Tray on GNOME** — third-party extension still required.
8. **Metainfo / screenshots** — Flathub blocker until polished.
9. **Build time / CI disk** — ggml Vulkan + flatpak-builder caches are
   heavy; budget runner resources like other GPU packaging jobs.

## Out of scope

- HIP / ROCm Flatpak
- Second Flathub package for CPU-only
- Snap
- Bundling Whisper / GGUF models inside the Flatpak
- Making ydotool / uinput the supported Flatpak injection path
- Guaranteeing dictation on every wlroots compositor
- Replacing Arch / Debian / AppImage channels
- Non-x86_64 (optional follow-up: aarch64 once x86_64 is green)

## Implementation order

1. Polish AppStream metainfo (and at least one real screenshot URL).
2. Implement portal EIS / RemoteDesktop libei path + clipboard fallback;
   keep native socket/ydotool chain for non-Flatpak builds.
3. Add `packaging/flatpak/im.apodaca.owlet.yml` with locked finish-args
   and Meson `-Dgpu_backend=vulkan`.
4. Add `build.sh` + Docker smoke using Flathub GNOME builder image.
5. Wire CI job; optionally `packaging/build.sh flatpak` + release
   bundle upload.
6. Update `README.md`, `AGENTS.md`, `docs/plans/README.md`, `.gitignore`.
7. Manual QA on GNOME and KDE: mic, model download, global shortcut,
   dictation inject, tray, remote API key.
8. (Follow-up) Open Flathub submission PR from the in-tree manifest.

## Verification checklist

1. [ ] `packaging/flatpak` smoke build produces an installable app /
   `.flatpak` for `im.apodaca.owlet` on the pinned GNOME runtime.
2. [ ] Manifest uses Vulkan Meson backend; no HIP modules; single app ID.
3. [ ] finish-args match the minimal set above (no `session-bus`, no
   `device=all`, no broad host filesystem).
4. [ ] Mic capture works via Pulse socket; model download lands under
   `~/.var/app/im.apodaca.owlet/data/owlet/models/`.
5. [ ] GlobalShortcuts bind works on GNOME (and KDE when available)
   without extra talk-names.
6. [ ] Dictation types via portal EIS/libei **or** documented clipboard
   fallback — not ydotool — when run as Flatpak.
7. [ ] Tray IconName resolves; SNI talk-name only.
8. [ ] `flatpak-builder-lint` / AppStream checks clean enough for Flathub.
9. [ ] README + release notes state Flatpak GPU scope (no HIP) and
   portal permission expectations.
10. [ ] Arch / Debian / AppImage packaging paths unchanged.
