# Phase 19 — 1.0 release readiness

> **Status:** planned (not started)
>
> Feature work for dictation, packaging (Arch / Debian / AppImage), and
> the tagged release workflow is largely in tree. This phase is the
> polish + hygiene gate before tagging **`v1.0.0`**.

## Goal

Ship a credible **Owlet 1.0** on the existing Linux channels (Arch,
Debian/Ubuntu `.deb`, AppImage) with real store metadata, consistent
versioning, fixed docs drift, a usable empty-model / manual-install path,
and CI that matches the libadwaita ≥ 1.8 build floor.

## Motivation

The app is past “scaffold”: local + remote transcription, dictation
(libei → ydotool → xdotool), global shortcuts, tray, HUD, sound
feedback, silence auto-stop, and multi-arch packaging already land. What
blocks calling it 1.0 is mostly **product identity and release hygiene**:

- AppStream / desktop files are still GNOME Builder placeholders.
- Meson + About still advertise `0.1.0`.
- CI runs on `ubuntu-latest` while packaging already requires Ubuntu
  26.04-class libadwaita.
- Plans index / AGENTS.md lag the code (including a merge conflict in
  `docs/plans/README.md`).
- First-run with no GGUF is a toast + empty stack, with no guided help
  for manual install.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Version | **`1.0.0`** in `meson.build`; About uses `Config.PACKAGE_VERSION` |
| Tag | **`v1.0.0`** → existing `.github/workflows/release.yml` |
| Channels | Arch + Debian + AppImage (x86_64 + aarch64; HIP x86_64 only) |
| Flatpak | **Out of scope** — remains phase 18 / post-1.0 |
| Model download catalog | **Deferred** — keep Tiny/Base/Small `.en` Q8_0; no catalog expansion in this phase (see Deferred below) |
| Manual GGUF help | **In scope** — help dialog + empty-state CTA (does not change the download list) |
| i18n locales | English source only; regenerate `po/owlet.pot` after new strings |
| Windows / macOS | Out of scope (`porting-windows-macos.md`) |
| Live mic / portal / GPU E2E | Stay manual (`docs/testing.md`) |

## Deferred (not this phase)

### Model download catalog

Preferences still hardcodes three Whisper `.en` Q8_0 downloads
(`src/ui/preferences.vala` `CATALOG` + `preferences.ui` ButtonRows).
Expanding to more Whisper sizes, multilingual variants, Parakeet, or
“all transcribe.cpp families / one quant each” needs a separate design
pass (grouping UI, size labels, streaming notes, network HEAD suite).

**Do not** change `CATALOG`, download ButtonRows, or
`tests/network/test_hf_urls.py` in this phase beyond whatever is
required for unrelated breakage. Track follow-up as a future phase once
catalog shape is decided.

### Flatpak / Flathub

Phase 18. Needs portal EIS / clipboard fallback work; not a 1.0 gate.

## Work items

### 1. AppStream metainfo (blocker)

Replace scaffold content in `data/im.apodaca.owlet.metainfo.xml.in`:

| Field | Action |
| --- | --- |
| `<summary>` | Real ≤ ~35-char product summary |
| `<description>` | Real paragraphs (local STT, dictation, GPU backends, remote API) |
| `<developer>` | Real developer id / name (match About) |
| `<url>` | Real homepage, vcs-browser, bugtracker; drop unused example.org URLs or point them at real pages |
| `<branding>` | Non-placeholder brand colors |
| `<screenshots>` | Hosted PNG/WebP of main window + Preferences (or omit until assets exist — do not ship `example.org` images) |
| `<releases>` | Entry for **1.0.0** with date + short notes; remove fake `1.0.1` |
| OARS | Generate real `oars-1.1` content rating |

Validate with `appstreamcli validate` (already in `meson test`).

### 2. Desktop file polish

`data/im.apodaca.owlet.desktop.in`:

- Replace template `Categories=Utility;` / `Keywords=GTK;` with
  sensible AudioVideo / Office (or Utility+) categories and keywords
  (speech, dictation, transcription, whisper, …).
- Keep `Name=Owlet`, `Icon=im.apodaca.owlet`, DBusActivatable as-is.

### 3. Version consistency (blocker)

| Location | Change |
| --- | --- |
| `meson.build` `project(… version:)` | `'1.0.0'` |
| `src/application.vala` `on_about_action` | `version = Config.PACKAGE_VERSION` (stop hardcoding `"0.1.0"`) |
| About extras | Add website / issue URL / license once AppStream URLs are real |
| Debian changelog / Arch pkgver | Driven by git / packaging scripts — verify tag `v1.0.0` produces coherent artifact names |

### 4. Docs hygiene (blocker for the plans tree)

- Resolve merge conflict markers in `docs/plans/README.md` (phase 17/18
  stash conflict).
- Index this phase in the phases table + open follow-ups.
- Refresh `AGENTS.md` “Plans status” so completed phases (8–17 packaging
  / tray / i18n pot / AppImage / silence auto-stop, etc.) are not listed
  as still open; point open work at 18 (Flatpak) + 19 (this) + deferred
  catalog.
- Add a short user-facing **Changelog** or release-notes blurb for 1.0
  (GitHub `generate_release_notes` alone is insufficient).

### 5. Manual GGUF install help + empty state

**Help dialog** (e.g. from Models page and/or Help menu):

- Where models live: `$XDG_DATA_HOME/owlet/models/` (document the usual
  `~/.local/share/owlet/models/` path).
- How to install manually: download a GGUF from
  [handy-computer on Hugging Face](https://huggingface.co/handy-computer)
  (or convert via transcribe.cpp docs), place it in that directory,
  optionally use **Open Models Directory**, then set default in
  Preferences.
- Note that in-app Download currently offers Whisper Tiny/Base/Small
  English only (no catalog change).

**Empty-state CTA** when no model is configured / load fails:

- Main window empty stack today toasts and leaves the user without a
  clear next step (`LocalSource.prepare` → window empty page).
- Add a primary action: open Preferences → Models, and/or open the help
  dialog.

No schema changes required unless a “don’t show again” preference is
desired (default: skip).

### 6. CI host alignment

`.github/workflows/ci.yml` today: `runs-on: ubuntu-latest` +
`libadwaita-1-dev`. Owlet needs **libadwaita ≥ 1.8**
(`Adw.ShortcutsDialog`); packaging already builds on **Ubuntu 26.04**.

- Switch CI to `ubuntu-26.04` (or whatever runner label matches the
  packaging floor), **or** an equivalent container job.
- Install the same X11 HUD deps if the default configure needs them
  (`libx11-dev`, `libxext-dev`, `libxrandr-dev`, …) so configure does
  not silently diverge from release builds.
- Keep CPU-only CI; Vulkan/HIP remain release-matrix / Docker smoke.

### 7. Tag and smoke

After the above lands on `main`:

1. Confirm `meson test` (unit + integration; UI if host allows).
2. Tag `v1.0.0` and let `release.yml` build Arch / Debian / AppImage
   artifacts.
3. Manual smoke checklist (one backend per channel is enough):
   - Install / run AppImage (CPU or Vulkan).
   - Preferences: download one existing Whisper entry **or** drop a
     manual GGUF and set default.
   - Record → transcript; Dictate → keystroke into a text editor.
   - Global shortcut or `owlet-signal` path once.
   - Close-to-tray (if testing on a DE with SNI) optional.

## Architecture notes

```
Empty / missing model
        │
        ▼
Window empty stack ──CTA──► Preferences Models
        │                         │
        │                         ├─ existing Download (3 Whisper .en)
        │                         ├─ Open Models Directory
        │                         └─ Help: manual GGUF install
        ▼
LocalSource.prepare (unchanged resolve path)
```

Version single source of truth:

```
meson.project_version() → config.h PACKAGE_VERSION
                        → Config.PACKAGE_VERSION (Vala)
                        → Adw.AboutDialog.version
```

## Out of scope

- Expanding or redesigning the in-app model download catalog.
- Flatpak / Flathub (phase 18).
- Non-English `.po` files.
- Automating live mic, portal bind UI, or GPU inference in CI.
- Cross-platform ports.

## Acceptance criteria

- [ ] `appstreamcli validate` passes on real metainfo (no example.org).
- [ ] Desktop file validates; categories/keywords are product-appropriate.
- [ ] `meson.project_version()` is `1.0.0`; About shows the same via
      `Config.PACKAGE_VERSION`.
- [ ] `docs/plans/README.md` has no conflict markers; phase 19 indexed.
- [ ] AGENTS.md plans status matches reality for open vs done phases.
- [ ] Help path exists for manual GGUF install; empty-state offers a
      clear next step.
- [ ] CI runs on a host with libadwaita ≥ 1.8 and green unit +
      integration (UI suite as today).
- [ ] `v1.0.0` release artifacts published and smoke-checked.
- [ ] Model `CATALOG` / download ButtonRows unchanged (deferred).

## Suggested commit sequence

1. Fix `docs/plans/README.md` conflict + add phase 19 index; refresh
   AGENTS.md status table.
2. AppStream + desktop metadata + screenshots (or drop broken screenshot
   URLs).
3. Version bump + About uses `Config.PACKAGE_VERSION` + changelog blurb.
4. Manual-install help dialog + empty-state CTA.
5. CI runner / deps alignment.
6. Tag `v1.0.0` after merge (release workflow).

## Follow-ups (post-1.0)

1. **Model catalog redesign** — separate phase once UI/scope is decided
   (curated Whisper+Parakeet vs all families / one quant, grouping,
   sizes, network tests).
2. Phase 18 Flatpak.
3. Optional non-English translations.
4. Optional packaging smoke job on `main` (CPU Arch or Debian Docker).
