# Phase 15 — Rename to Owlet (`im.apodaca.owlet`)

## Goal

Rename the application from **Kaki** / `org.kaki.app` to **Owlet** /
`im.apodaca.owlet` across the full identity surface: display name, app
id, GResource and GSettings paths, binary, signal helper, XDG data dir,
meson/gettext package, Vala type prefix, icons, tests, packaging, and
docs. Present Owlet as the current product name — do **not** document
this as a rename or “formerly Kaki” in README / user-facing copy.

## Motivation

Establish a stable reverse-DNS identity under `im.apodaca` and a product
name that matches the intended brand.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Depth | **Full identity remap** (not app-id-only) |
| Display name | Owlet |
| Application ID | `im.apodaca.owlet` |
| GResource / GSettings path | `/im/apodaca/owlet` (schema path `/im/apodaca/owlet/`) |
| Binary | `owlet` |
| Signal helper | `owlet-signal` (source `data/owlet-signal.sh`) |
| Pidfile | `$XDG_RUNTIME_DIR/owlet.pid` (fallback `/tmp/owlet.pid`) |
| XDG data dir | `$XDG_DATA_HOME/owlet/` (models under `…/owlet/models/`) |
| Meson project / gettext | `owlet` |
| Vala type prefix | `Owlet.*` (replace `Kaki.*`) |
| Icons | `im.apodaca.owlet.svg`, `-symbolic`, `-recording-symbolic` |
| Test env vars | `OWLET_BIN`, `OWLET_SOURCE_ROOT`, `OWLET_DOWNLOAD_CLI`, `OWLET_REMOTE_CLI` |
| Arch packages | `pkgbase=owlet` → `owlet`, `owlet-vulkan`, `owlet-hip`; env `OWLET_BACKEND` |
| User-data migration | **None** — clean break (settings, models, libsecret schema) |
| GitHub / remote rename | Out of tree for this phase; implementer updates in-repo URLs to the new name; no “renamed from” wording |
| Checkout directory | Leave local folder name alone unless the developer moves it |
| Submodule | Do not touch `subprojects/transcribe.cpp` |

## Identity map

| Role | Before | After |
| --- | --- | --- |
| Display name | Kaki | Owlet |
| App ID | `org.kaki.app` | `im.apodaca.owlet` |
| Resource / settings path | `/org/kaki/app` | `/im/apodaca/owlet` |
| Binary | `kaki` | `owlet` |
| Helper | `kaki-signal` | `owlet-signal` |
| Pidfile | `kaki.pid` | `owlet.pid` |
| XDG share leaf | `kaki` | `owlet` |
| Meson / gettext | `kaki` | `owlet` |
| Vala prefix | `Kaki.` | `Owlet.` |
| Icon basenames | `org.kaki.app*` | `im.apodaca.owlet*` |
| pytest env | `KAKI_*` | `OWLET_*` |
| Arch pkg / install hook | `kaki` / `kaki.install` | `owlet` / `owlet.install` |

## Scope by area

### 1. Meson project + binaries

- Root `meson.build`: `project('owlet', …)`; `GETTEXT_PACKAGE` /
  `-DGETTEXT_PACKAGE=` → `owlet`.
- `src/meson.build`: executable `owlet`; rename meson identifiers
  (`kaki` → `owlet`, `kaki_sources` → `owlet_sources`, etc.);
  `gnome.compile_resources('owlet-resources', 'owlet.gresource.xml',
  c_name: 'owlet')`; `run_target` + `GSETTINGS_SCHEMA_DIR`.
- `tests/meson.build`: set `OWLET_*` env from the renamed targets.
- `tests/helpers/meson.build`: executables `owlet-download-cli`,
  `owlet-remote-cli`.
- `po/`: gettext package `owlet`; rename `po/kaki.pot` → `owlet.pot`;
  update `POTFILES.in` for new `data/im.apodaca.owlet.*` paths;
  update any `meson` i18n / `*-update-po` naming that embeds `kaki`.

### 2. Desktop / AppStream / D-Bus / GSettings / icons / helper

Rename and rewrite under `data/`:

| Before | After |
| --- | --- |
| `org.kaki.app.desktop.in` | `im.apodaca.owlet.desktop.in` |
| `org.kaki.app.metainfo.xml.in` | `im.apodaca.owlet.metainfo.xml.in` |
| `org.kaki.app.gschema.xml` | `im.apodaca.owlet.gschema.xml` |
| `org.kaki.app.service.in` | `im.apodaca.owlet.service.in` |
| `kaki-signal.sh` | `owlet-signal.sh` |
| `icons/…/org.kaki.app*.svg` | `icons/…/im.apodaca.owlet*.svg` |

Content updates:

- Schema `id="im.apodaca.owlet"` `path="/im/apodaca/owlet/"`.
- Desktop: `Name=Owlet`, `Exec=owlet`, `Icon=im.apodaca.owlet`.
- Metainfo: `<id>`, `<name>`, `<launchable>`, `<translation type="gettext">owlet</translation>`;
  optionally set `<developer id="im.apodaca">` while editing (placeholders
  today).
- D-Bus service: `Name=im.apodaca.owlet`, `Exec=@bindir@/owlet --gapplication-service`.
- Helper: usage strings, pidfile `owlet.pid`, `notify-send -a owlet -i im.apodaca.owlet`.
- `data/meson.build` + `data/icons/meson.build`: all input/output/
  `application_id` / install rename paths.

### 3. Vala / UI / gresource

- Rename `src/kaki.gresource.xml` → `src/owlet.gresource.xml`;
  prefix `/im/apodaca/owlet`; alias `owlet-signal.sh`.
- Mechanical replacements across `src/**/*.vala` and `src/**/*.ui`:
  - `Kaki.` → `Owlet.`
  - `org.kaki.app` → `im.apodaca.owlet`
  - `/org/kaki/app` → `/im/apodaca/owlet`
  - XDG leaf `"kaki"` → `"owlet"` (`local-source.vala`, `preferences.vala`, …)
- `application.vala`: `application_id`, `resource_base_path`, About
  dialog name/icon, pidfile path, comments referring to the helper.
- `tray.vala`: `IDLE_ICON` / `RECORDING_ICON`, tooltips (`Owlet`,
  `Owlet — Recording`); comment that mentions generated
  `kaki_tray_set_recording` → `owlet_…`.
- `preferences.vala` / `.ui`: gresource paths, install/copy helper
  command `owlet-signal toggle`, models-dir description
  `~/.local/share/owlet/models/`.
- Window title / `_About Owlet` menu label.

### 4. Tests

- `tests/conftest.py`: binary paths under `build/src/owlet`, helper
  paths, schema src `data/im.apodaca.owlet.gschema.xml`, env var names.
- `tests/unit/test_gresource.py`: expected `/im/apodaca/owlet/…` paths.
- `tests/unit/test_gsettings.py` and integration/UI tests: any
  `org.kaki.app` / `kaki` / `KAKI_` leftovers (schema id, labels,
  log filenames, shell snippets).
- `tests/README.md`: env examples (`OWLET_BIN=…`).

### 5. Current docs + packaging (no rename narrative)

Update **current-state** docs and packaging only:

- `AGENTS.md`, `README.md`, `docs/testing.md`
- `packaging/arch/PKGBUILD` + rename `kaki.install` → `owlet.install`;
  `OWLET_BACKEND`; `url=` to the new GitHub repo name the maintainer will
  create

Do **not** rewrite other files under `docs/plans/` (phases 0–12 stay as
historical records). Phases 13 and 14 (`phase-13-dictation-hud.md`,
`phase-14-debian-packaging.md`) are exceptions: they are not yet
implemented, so they are updated to Owlet identity in-tree. Indexing
this phase in `docs/plans/README.md` is already done.

Do **not** add migration notes, changelog “renamed from Kaki”, or
similar — present Owlet as the current product name.

### 6. Out of scope

- Runtime migration of GSettings, `~/.local/share/kaki`, or libsecret
  entries under schema `org.kaki.app`
- `gh` / GitHub repository rename (maintainer-owned)
- Renaming the on-disk developer checkout directory
- Any change inside `subprojects/transcribe.cpp`
- Editing historical phase plans (`docs/plans/phase-0`…`12`); they may
  still say Kaki / `org.kaki.app`. Phases 13–14 are already
  Owlet-aligned and must stay that way.

## Implementation order

1. Rename `data/` and icon files; update `data/meson.build` /
   `icons/meson.build`.
2. Rename gresource + meson project/executable/helpers/gettext.
3. Sweep Vala/UI for id, path, namespace, XDG, and user-visible strings.
4. Sweep tests + env vars.
5. Sweep docs + Arch packaging.
6. Wipe or reconfigure build dirs; build and run the verification list.

Work on a Worktrunk feature branch per `AGENTS.md`
(`wt switch --create <branch> --no-cd …`).

## Verification

```bash
# Fresh configure after the rename (stale build-* dirs will lie)
meson setup --wipe build   # or rm -rf build && meson setup build
ninja -C build
meson test -C build --suite unit --print-errorlogs
ninja -C build run
```

Manual checks:

1. About dialog / window title show **Owlet**; icon name
   `im.apodaca.owlet`.
2. `gsettings list-recursively im.apodaca.owlet` works with
   `GSETTINGS_SCHEMA_DIR=build/data`.
3. Models path resolves under `~/.local/share/owlet/models/`.
4. Preferences “copy helper command” yields `owlet-signal toggle`;
   pidfile is `$XDG_RUNTIME_DIR/owlet.pid`.
5. `strings build/src/owlet | grep -E '^/im/apodaca/owlet/'` lists UI /
   sample / signal resources.
6. `rg -n 'org\.kaki\.app|/org/kaki/app|\bkaki\b|\bKaki\b' --glob '!subprojects/**' --glob '!build*/**' --glob '!docs/plans/phase-{0..12}*.md'`
   is empty of product-identity hits outside historical phase plans
   (phases 13–14 must already be Owlet-clean).

## Risks

- **Breaking change** for any prior install: old schema, secrets, models
  path, and custom shortcuts bound to `kaki-signal` no longer apply
  (accepted; no migration).
- Incomplete `Kaki.` / path sweep fails the Vala build — treat compile
  errors as the primary leftover detector, then `rg` for docs/tests.
- Leftover `build`, `build-cpu`, `build-vulkan`, `build-hip` confuse
  pytest binary paths until wiped/reconfigured.