# Phase 10 — Close to tray

## Goal

Add a Preferences option so the window close button can hide Kaki to a
system tray icon instead of quitting. The process stays alive for
background dictation and global shortcuts. Tray menu: **Show**,
**Dictate**, **Quit**. Explicit Quit / Ctrl+Q still exits. While the
mic is recording, the tray icon shows a **red record light** so the
user can see capture is active without opening the window.

## Motivation

Dictation already minimizes Kaki for focus handoff (`Window.minimize()`
in `start_dictation`). That is not the same as staying resident without
a taskbar entry. Users who want quick show/hide plus always-on global
dictation need close → hide + tray restore.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| What hides to tray | **Close button only**, gated by a Preferences switch |
| Why | Background dictation **and** quick show/hide |
| Tray menu | Show, Dictate, Quit (left-click = Show) |
| Recording indicator | Idle = `org.kaki.app`; recording = `org.kaki.app-recording` (app icon + red record light) |
| Backend | Hand-rolled **StatusNotifierItem + DBusMenu** over GIO (Vala). No new pkg-config deps. |
| Default | `close-to-tray` = `false` |

**Why not AppIndicator / ayatana?** Classic `libayatana-appindicator` is
GTK3 and cannot link with GTK4. `libayatana-appindicator-glib` is
GTK-free but uses GMenu instead of classic dbusmenu (weak host support)
and is barely packaged yet. Pure GIO SNI + `com.canonical.dbusmenu` is
the GTK4-safe, widely compatible path (KDE, XFCE, Cinnamon, Waybar,
GNOME with AppIndicator extension).

## Behavior matrix

| Action | Pref off (default) | Pref on |
| --- | --- | --- |
| Window close (X) | Quit (current) | Hide window + show tray |
| Ctrl+Q / `app.quit` / tray Quit | Quit | Quit |
| Tray Show / left-click | — | `present()` window, tear down tray |
| App re-launch / `activate` | Present or create window | Present hidden window, tear down tray |
| Tray Dictate | — | `toggle_dictation()` while hidden |
| Global shortcut / `kaki-signal` | Works if window exists | Must keep working while hidden |
| Mic recording (Record or Dictate) | — | Tray switches to recording icon + tooltip |
| Recording stops | — | Tray returns to idle icon + tooltip |

Dictation’s existing `minimize()` path is **unchanged** (taskbar
minimize for focus handoff only). The red light tracks **mic
recording** (UI `recording` flag / recorder start–stop), not “dictating
but not yet recording” during the 250 ms minimize delay.

## Critical constraint

Global shortcut handlers use `(this.active_window as Kaki.Window)?`
(`application.vala` ~179–188). If close **destroys** the window, shortcuts
become no-ops even if the process is held alive.

**Must hide, not destroy.** `close_request` → `hide()` + return `true`
when the pref is on. The `Kaki.Window` instance stays registered with
`Gtk.Application`.

## Architecture

```
Preferences SwitchRow (close-to-tray)
        │ bind
        ▼
GSettings close-to-tray
        │
        ▼
Window.close_request
        │ if true: hide() + Application.show_tray()
        │ else: allow destroy → last window quit
        ▼
Kaki.Tray (SNI + DBusMenu over session bus)
        │ Activate / Show  → present window, hide_tray()
        │ Dictate          → active_window.toggle_dictation()
        │ Quit             → app.quit
        │ set_recording()  ← Window on recording_started / stopped
        ▼
StatusNotifierWatcher (desktop host)
        IconName idle | recording
```

## Recording indicator

### Visual

Ship a second hicolor scalable icon next to the existing app icon:

| Name | Use |
| --- | --- |
| `org.kaki.app` | Idle (already installed) |
| `org.kaki.app-recording` | Mic active — same mark, plus a clear **red record light** (filled circle) in a corner |

Do **not** rely on SNI `OverlayIconName` / `AttentionIcon` alone — host
support is uneven. Swap the primary `IconName` and emit
`NewIcon` so KDE/XFCE/Cinnamon/Waybar/GNOME-AppIndicator all pick it up.

Also update tooltip:

- Idle: `Kaki`
- Recording: `Kaki — Recording`

Optional (nice-to-have, not required): set SNI `Status` to
`NeedsAttention` while recording if it helps emphasis on a given host;
primary UX is the red-light icon swap.

### State source

Wire from `Kaki.Window`’s existing recorder lifecycle (same moments the
UI flips `recording`):

- On `recording_started` (or wherever `recording = true` is set) →
  `tray.set_recording (true)` if tray is visible (or always push state
  so a later `tray.show()` opens with the correct icon).
- On `recording_stopped` / finalize path that clears `recording` →
  `tray.set_recording (false)`.

Cover both in-window **Record** and **Dictate** (dictate eventually
starts the recorder). During the 250 ms pre-record delay, stay on the
idle icon until the mic is actually open.

Application owns the tray; Window notifies via a thin app method
(e.g. `application.set_tray_recording (bool)`) or a signal — avoid
Window constructing its own `Tray`.

### Icon asset

Create `data/icons/hicolor/scalable/apps/org.kaki.app-recording.svg`:

- Base: copy/`use` the existing `org.kaki.app.svg` artwork.
- Add a red filled circle (record light), typically bottom-right, large
  enough to read at 16–22 px tray sizes (solid `#e01b24` or similar;
  high contrast on both light and dark panels).
- Install via `data/icons/meson.build` next to the existing scalable
  install. No symbolic recording variant required unless a host only
  shows symbolic tray icons (unlikely for SNI theme names).

## Out of scope

- Minimize button → tray
- Autostart / start minimized
- Blinking / animated record light
- Separate “dictating but not recording” tray state
- Windows / macOS tray (`docs/plans/porting-windows-macos.md`)
- Changing Shortcuts dialog (Phase 8) beyond optional mention

## Files to create

### `src/services/tray.vala`

```vala
public class Kaki.Tray : GLib.Object {
    public signal void show_requested ();
    public signal void dictate_requested ();
    public signal void quit_requested ();

    public bool visible { get; private set; }
    public bool recording { get; private set; }

    public void show ();              // export SNI + menu; no-op if already shown
    public void hide ();              // unregister; no-op if not shown
    public void set_recording (bool active);  // swap IconName + tooltip; emit NewIcon
}
```

Responsibilities:

- Own a unique `org.kde.StatusNotifierItem` (or
  `org.freedesktop.StatusNotifierItem`) object path on the session bus.
- Register with `org.kde.StatusNotifierWatcher` via `RegisterStatusNotifierItem`.
- Export a flat `com.canonical.dbusmenu` with three items: Show, Dictate,
  Quit (separators optional).
- `Activate` (left-click) → `show_requested`.
- `ContextMenu` / menu AboutToShow → host shows the dbusmenu.
- Icon / tooltip:
  - Idle: `IconName=org.kaki.app`, tooltip `Kaki`
  - Recording: `IconName=org.kaki.app-recording`, tooltip `Kaki — Recording`
  - On `set_recording`, update properties and emit `NewIcon` (and
    `NewToolTip` if the host watches it). Remember the flag so `show()`
    after a mid-session hide/show still opens with the right icon.
- Title: `Kaki` (stable).
- If no watcher is present, `show()` fails softly (warning log); hide
  still works and restore via app re-launch / D-Bus activate remains.

Keep the SNI surface otherwise minimal: Category=`ApplicationStatus`,
Status=`Active` (or `NeedsAttention` only if we opt into that while
recording), ItemIsMenu=`false` so left-click Activate works on hosts
that support it (KDE, XFCE, Waybar). Flat menu only — no submenus or
check/radio items.

Reference implementations conceptually (do not vendor blindly):
Nicotine+ SNI, libsni-exporter, freedesktop StatusNotifierItem spec.

## Files to modify

| File | Change |
| --- | --- |
| `data/org.kaki.app.gschema.xml` | Add `close-to-tray` boolean key, default `false` |
| `data/icons/hicolor/scalable/apps/org.kaki.app-recording.svg` | **Create** — app icon + red record light |
| `data/icons/meson.build` | Install the recording SVG next to `org.kaki.app.svg` |
| `src/ui/preferences.ui` | New General-page group after Transcription (~line 117): `AdwSwitchRow` “Close to tray” |
| `src/ui/preferences.vala` | GtkChild + `settings.bind` in `populate_general_page` (same pattern as `streaming_row`) |
| `src/window.vala` | Connect `close_request`; when pref on, `hide()` + notify app, return `true`; call app tray recording updates on start/stop |
| `src/application.vala` | Own `Kaki.Tray`; wire Show / Dictate / Quit; restore on `activate`; react to pref changes; `set_tray_recording` |
| `src/meson.build` | Add `services/tray.vala` to `kaki_sources` |
| `AGENTS.md` | Architecture bullet: tray = GIO SNI; recording swaps `org.kaki.app-recording`; GNOME AppIndicator caveat |

No new meson `dependency()` entries — GIO comes with GTK4/glib.

## GSettings key

```xml
<key name="close-to-tray" type="b">
  <default>false</default>
  <summary>Hide to system tray on window close</summary>
  <description>When true, closing the main window hides Kaki to a StatusNotifierItem tray icon instead of quitting. Use Quit (Ctrl+Q) or the tray Quit item to exit. On GNOME Shell, an AppIndicator / KStatusNotifierItem extension is required for the icon to appear.</description>
</key>
```

Place with the other boolean prefs in `data/org.kaki.app.gschema.xml`
(near `dictation-*` / Phase 4 keys is fine).

## Preferences UI

New group on the General page (after the Transcription group that ends
~line 117 of `preferences.ui`):

```xml
<object class="AdwPreferencesGroup">
  <property name="title" translatable="yes">Window</property>
  <child>
    <object class="AdwSwitchRow" id="close_to_tray_row">
      <property name="title" translatable="yes">Close to tray</property>
      <property name="subtitle" translatable="yes">Hide to the system tray instead of quitting. On GNOME, enable an AppIndicator extension.</property>
    </object>
  </child>
</object>
```

Bind:

```vala
settings.bind ("close-to-tray", close_to_tray_row, "active",
               GLib.SettingsBindFlags.DEFAULT);
```

## Application wiring details

1. Construct `Kaki.Tray` in `startup` (or lazily on first hide). Connect:
   - `show_requested` → present main window, `tray.hide()`
   - `dictate_requested` → `(active_window as Window)?.toggle_dictation()`
   - `quit_requested` → `this.quit()`
2. Method for window: `request_hide_to_tray()` → `tray.show()` (window
   already called `hide()`).
3. `activate()` (~220–224): if a window exists but is not visible,
   `present()` it and `tray.hide()`; else create as today.
4. Live pref change: if `close-to-tray` flips to `false` while the
   window is hidden, `present()` and `tray.hide()` so the user is not
   stuck without a restore path from the pref UI alone.
5. `app.quit` / shutdown: `tray.hide()` before teardown; remove pidfile
   as today.
6. Recording: Window notifies Application whenever `recording` flips;
   Application calls `tray.set_recording (...)`. Safe to call when the
   tray is not visible (cache state for the next `show()`).

Do **not** call `Application.hold()` solely for this — a hidden
`Gtk.Window` still counts as an open window for GApplication quit
policy. Verify on implement; only add `hold()`/`release()` if testing
shows the process exits on hide.

## Acceptance criteria

- [ ] Pref off: close quits as today; no tray icon.
- [ ] Pref on: close hides the window; tray icon appears (on hosts with
      a StatusNotifierWatcher).
- [ ] Tray Show / left-click / app re-launch restores the window and
      removes the tray icon.
- [ ] Tray Dictate toggles dictation while the window is hidden;
      keystroke injection still targets the previously focused app.
- [ ] Global portal shortcut and `kaki-signal toggle` work while
      tray-hidden.
- [ ] Tray Quit and Ctrl+Q fully exit (pidfile removed, no leftover
      tray registration).
- [ ] No StatusNotifierWatcher: hide still succeeds; restore via
      launching Kaki again (D-Bus single-instance `activate`).
- [ ] Default remains off; meson build needs no new system packages.
- [ ] While tray-hidden and recording (Record or Dictate), tray shows
      `org.kaki.app-recording` (visible red record light) and recording
      tooltip; on stop, idle icon/tooltip return.
- [ ] Close to tray *during* an active recording already shows the
      recording icon immediately (state applied on `show()`).
- [ ] Pre-record 250 ms dictate delay does **not** show the red light
      until the mic actually starts.

## Manual test notes

Automated coverage is awkward (needs a session bus tray host). Manual:

1. KDE / XFCE / Cinnamon / Waybar — full path.
2. GNOME without extension — hide works, no icon; re-launch restores.
3. GNOME with AppIndicator extension — icon + menu.
4. Mid-dictation close-to-tray — recording continues; stop via global
   shortcut or tray Dictate; red light on while mic open, off when
   stopped.
5. Tray-hidden → Record via global toggle → red light appears without
   opening the window; stop → idle icon.
6. Toggle pref off while hidden — window reappears.

## Worktrunk

Feature branch via Worktrunk (see `AGENTS.md`):

```bash
wt switch --create close-to-tray --no-cd --format json -y
cd .worktrees/close-to-tray
git submodule update --init --recursive
meson setup build && ninja -C build
```

## Related

- Phase 3 — dictation minimize (orthogonal; leave alone)
- Phase 5 — global shortcuts must keep working while hidden
- Phase 4 — Preferences General page pattern
- `AGENTS.md` — optional-dep and architecture notes