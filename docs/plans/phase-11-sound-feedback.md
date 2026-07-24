# Phase 11 — Sound feedback

## Goal

Play distinct short tones when recording starts and stops (dictation
**and** Record/Stop), with a Preferences option to disable.

## Motivation

Global dictation minimizes the window, so the Dictate toggle is often
invisible. Audible cues confirm the mic is live and that stop was
registered.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Assets | Bundled custom sounds in gresource (two distinct short tones) |
| Triggers | Dictation **and** in-window Record/Stop |
| Start timing | After mic actually starts (`recording_started`) |
| Stop timing | On stop **request** (`on_stop` / `stop_dictation` when calling `recorder.stop()`), not after finalize |
| Cancel during 250 ms delay | No start was played → no stop sound |
| Pref | `sound-feedback` (boolean), **default `true`** |
| Playback | `Gtk.MediaFile.for_resource()` (GTK4 already linked); hold refs until EOS |
| Pref UI | General → new **Feedback** group, one SwitchRow |

## Behavior matrix

| Action | Pref on (default) | Pref off |
| --- | --- | --- |
| Record / Dictate → mic starts | Start tone | Silent |
| Stop / Dictate off while recording | Stop tone | Silent |
| Dictate off during 250 ms delay | Silent | Silent |
| Recorder start failure | No start tone | — |

## Architecture

```
Preferences SwitchRow (sound-feedback)
        │ bind
        ▼
GSettings sound-feedback
        │
        ▼
Kaki.SoundFeedback.play_start() / play_stop()
        │ if !get_boolean → return
        │ Gtk.MediaFile.for_resource("/org/kaki/app/sounds/…")
        ▼
Window.on_recording_started  → play_start()
Window.on_stop / stop_dictation (when recording) → play_stop()
```

Single start hook (`on_recording_started`) covers Record and Dictate
(including the post-minimize timeout path).

## Out of scope

- Theme / Freedesktop event sounds (libcanberra)
- Volume slider or custom sound picker
- Visual / tray recording indicator (phase 10)
- Shortcuts dialog changes (phase 8)

## Files to create

### `src/sounds/start.ogg` and `src/sounds/stop.ogg`

Short (~80–150 ms) mono tones, clearly different (e.g. higher blip for
start, lower for stop). Generate with `sox`/`ffmpeg` at implement time;
check into the repo as binary assets.

### `src/services/sound-feedback.vala`

```vala
public class Kaki.SoundFeedback : GLib.Object {
    public SoundFeedback (GLib.Settings settings);
    public void play_start ();
    public void play_stop ();
}
```

Responsibilities:

- Gate on `settings.get_boolean ("sound-feedback")`.
- Resource paths: `/org/kaki/app/sounds/start.ogg`, `…/stop.ogg`.
- Keep `Gtk.MediaFile` instances alive until finished (or replace on
  next play) so GC does not cut audio short.
- Fail softly on missing resource / playback error (`warning` only).

## Files to modify

| File | Change |
| --- | --- |
| `data/org.kaki.app.gschema.xml` | Add `sound-feedback` boolean key, default `true` |
| `src/kaki.gresource.xml` | Alias both OGG files under `/org/kaki/app/sounds/` |
| `src/meson.build` | Add `services/sound-feedback.vala` to `kaki_sources` |
| `src/window.vala` | Own a `SoundFeedback`; call `play_start` in `on_recording_started` (~298); call `play_stop` in `on_stop` (~333) and in `stop_dictation` when `recording` (~445–446) |
| `src/ui/preferences.ui` | Feedback group + SwitchRow after Transcription (~117) |
| `src/ui/preferences.vala` | `[GtkChild]` + `settings.bind` in `populate_general_page` (mirror `streaming_row` ~169–173) |
| `docs/plans/README.md` | Row for phase 11 |
| `AGENTS.md` | Plans status table: phase 11 |

No new meson `dependency()` entries — GTK4 MediaFile is enough.

## GSettings key

```xml
<key name="sound-feedback" type="b">
  <default>true</default>
  <summary>Play sounds when recording starts and stops</summary>
  <description>When true, short tones play after the microphone starts and when the user stops recording or dictation.</description>
</key>
```

Place with the other boolean prefs in `data/org.kaki.app.gschema.xml`
(near `dictation-*` / Phase 4 keys is fine).

## Preferences UI

New group on the General page (after the Transcription group that ends
~line 117 of `preferences.ui`):

```xml
<object class="AdwPreferencesGroup">
  <property name="title" translatable="yes">Feedback</property>
  <child>
    <object class="AdwSwitchRow" id="sound_feedback_row">
      <property name="title" translatable="yes">Sound feedback</property>
      <property name="subtitle" translatable="yes">Play a tone when recording starts and stops</property>
    </object>
  </child>
</object>
```

Bind:

```vala
settings.bind ("sound-feedback", sound_feedback_row, "active",
               GLib.SettingsBindFlags.DEFAULT);
```

## Window wiring details

1. Construct `Kaki.SoundFeedback` in `Window` construct / ctor, passing
   the existing `GLib.Settings ("org.kaki.app")` instance.
2. `on_recording_started` (~298): after setting `recording = true`, call
   `sound_feedback.play_start ()`.
3. `on_stop` (~333): before `recorder.stop ()`, call
   `sound_feedback.play_stop ()`.
4. `stop_dictation` (~442): when `recording` is true and about to call
   `recorder.stop ()`, call `sound_feedback.play_stop ()`. Do **not**
   play stop when clearing dictation during the 250 ms delay (no start
   was played).
5. Prefer calling `play_stop` only once per stop. If both `on_stop` and
   `stop_dictation` can run for the same user action, gate so the tone
   fires a single time (e.g. only from `on_stop`, and have
   `stop_dictation` rely on `recorder.stop ()` → same path — or only
   from the call site that invokes `recorder.stop ()`).

Recommended: play stop immediately before every `recorder.stop ()`
call site (`on_stop` and `stop_dictation`); those paths are mutually
exclusive for a given session stop.

## Acceptance criteria

- [ ] Dictate on (after mic live) → start tone; Dictate off while
      recording → stop tone (distinct)
- [ ] Record / Stop → same tones
- [ ] Pref off → silence for all of the above
- [x] Pref default is on for a fresh schema
- [ ] Cancel dictate during 250 ms delay → no tones
- [ ] Overlapping rapid toggle does not crash; at most one tone plays
      at a time (latest wins is fine)
- [x] `meson test -C build --suite unit` still passes (schema compile)

## Manual test notes

1. Schema dir + run uninstalled (per `AGENTS.md`).
2. Toggle Dictate via header and via global shortcut / `kaki-signal`.
3. Toggle Sound feedback off/on without restart; verify bind is live.
4. Confirm start and stop are audibly different.

## Worktrunk

Feature branch via Worktrunk (see `AGENTS.md`):

```bash
wt switch --create phase-11-sound-feedback --no-cd --format json -y
cd .worktrees/phase-11-sound-feedback
git submodule update --init --recursive
meson setup build && ninja -C build
```

## Related

- Dictation flow: `src/window.vala` `start_dictation` / `stop_dictation`
  / `on_recording_started`
- Phase 10 (tray) is independent; sounds do not depend on tray
- Phase 4 — Preferences General page pattern