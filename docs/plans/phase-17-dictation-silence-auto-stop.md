# Phase 17 — Dictation silence auto-stop

## Goal

When the opt-in Preference is enabled, **dictation** automatically stops
after a user-adjustable stretch of silence (including if the user never
speaks): stop recording, finalize/type the transcript, return to idle —
the same outcome as manually toggling Dictate off.

Regular in-app **Record** stays manual start/stop.

## Motivation

Dictation today only ends on an explicit stop. That breaks hands-free
use, leaves the mic open when people forget to stop, and differs from
familiar OS / Whisper-style “speak, pause, done” behavior.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Scope | **Dictation only** (`dictating == true`); Record unchanged |
| After pause | **End utterance** — `stop_dictation()`; do not keep listening |
| Opt-in | `dictation-auto-stop` default **`false`** |
| Pause length | User-adjustable `dictation-auto-stop-pause-ms` |
| Default pause | **1200** ms |
| Allowed range | **500–5000** ms (UI step 100) |
| Silent start | **Same pause rule** from mic-open — no “must speak once” grace |
| Detection | **Host-side RMS** on `Recorder.chunk_ready` PCM (16 kHz mono F32LE) |
| Model VAD / Whisper `no_speech` | **Out of scope** — not a live end-of-utterance signal |
| Energy threshold | Fixed constant in v1 (no Preferences slider) |
| Stop path | Call **`stop_dictation()`** only (not `on_stop()`) |
| False stop | Acceptable — easy restart via toggle/shortcut; typed text stays |
| Pref UI | General → Feedback: SwitchRow + SpinRow (spin sensitive when on) |

## Why host-side RMS (not the engine)

transcribe.cpp does not expose usable live VAD for this. Whisper
`no_speech_*` is post-decode chunk discard, not “user stopped talking.”
Family docs treat VAD as unsupported. Owlet already gets every capture
chunk via `chunk_ready`; measuring RMS there drives the existing stop
path without submodule or VAPI changes.

## Current behavior (baseline)

- Dictate on/off: `start_dictation` / `stop_dictation` in
  `src/window.vala` (~441–519). Global/tray use
  `toggle_dictation_background()`; in-window uses `on_dictate_toggle`.
- `Recorder` (`src/services/recorder.vala`) emits `chunk_ready` on the
  **GStreamer streaming thread** with F32LE mono @ 16 kHz. No level API.
- `Window.on_chunk` (~356–369) feeds streaming / batch only; ignores
  silence.
- Feedback prefs today: `sound-feedback`, `dictation-hud`
  (`preferences.ui` ~119–134; binds in `preferences.vala` ~177–180).

## Architecture

```
Preferences Feedback
  SwitchRow  dictation-auto-stop          (default false)
  SpinRow    dictation-auto-stop-pause-ms (default 1200; 500–5000)
        │
        ▼
GSettings
        │
        ▼
Recorder.chunk_ready  (GST thread)
        │
        ▼
Window.on_chunk
        ├─ existing stream_feed / batch_buf
        └─ if dictating && auto-stop enabled:
             SilenceDetector.observe(samples)
             if pause elapsed:
               Idle.add → stop_dictation()   // main thread
                                │
                                ▼
                     same path as manual Dictate off
                     (stop tone, EOS, finalize, type, clear)
```

Silence clock:

1. Each chunk’s duration = `samples.length / 16000` seconds.
2. If RMS ≥ fixed speech threshold → treat as speech; **reset** silence
   accumulator to 0.
3. If RMS &lt; threshold → add chunk duration to silence accumulator.
4. When silence accumulator ≥ `dictation-auto-stop-pause-ms` → request
   stop once (dedupe until `reset()` on next dictation start).

Because the clock runs from the first chunk, never speaking still ends
the session after the configured pause (locked decision).

## Behavior matrix

| Situation | Pref off (default) | Pref on |
| --- | --- | --- |
| Dictation + speaking, then pause ≥ N ms | Keep recording | `stop_dictation()` |
| Dictation + never speak for ≥ N ms | Keep recording | `stop_dictation()` |
| Dictation + brief mid-sentence pause &lt; N | Keep recording | Keep recording |
| Pure Record (not dictating) | Manual only | Manual only (tracker idle) |
| Manual Dictate off / Stop while dictating | As today | As today (cancel pending auto-stop) |
| Record then enable Dictate mid-session | — | Tracker applies once `dictating` |

| Entry point | Auto-stop applies when pref on? |
| --- | --- |
| In-window Dictate | Yes (after mic live / chunks) |
| Global shortcut Dictate | Yes |
| Tray Dictate | Yes |
| Record only | No |

## Files to create

### `src/services/silence-detector.vala`

```vala
public class Owlet.SilenceDetector : GLib.Object {
    public int pause_ms { get; set; default = 1200; }

    public void reset ();
    /** @return true once when silence has lasted ≥ pause_ms */
    public bool observe (float[] samples, int sample_rate = 16000);
}
```

Responsibilities:

- Compute RMS over the chunk; compare to a **named constant** threshold
  (tune against real mic noise at implement time; document the constant
  in a one-line comment).
- Accumulate silence time; reset on speech; return `true` at most once
  per `reset()` cycle after the pause elapses.
- Pure / testable — no GSettings, GTK, or GStreamer deps.
- Sample rate default 16000 to match the recorder caps.

## Files to modify

| File | Change |
| --- | --- |
| `data/im.apodaca.owlet.gschema.xml` | Add `dictation-auto-stop` (b, false) and `dictation-auto-stop-pause-ms` (i, 1200); document range in `<description>` |
| `src/services/silence-detector.vala` | New (see above) |
| `src/meson.build` | Add `services/silence-detector.vala` to `owlet_sources` (~near sound-feedback / dictation-hud) |
| `src/window.vala` | Own a `SilenceDetector`; reset on dictation start / clear; in `on_chunk` (~356–369) observe when `dictating` && pref on; `Idle.add` → `stop_dictation()`; ignore further fires until reset |
| `src/ui/preferences.ui` | Feedback group (~119–134): SwitchRow + SpinRow after Dictation overlay |
| `src/ui/preferences.vala` | `[GtkChild]` rows; bind switch; sync spin like `cpu_threads_row` (~166–170); `sensitive` on spin when switch active |
| `tests/unit/test_gsettings.py` | Add expected defaults for the two new keys to `EXPECTED_DEFAULTS` |
| `docs/plans/README.md` | Phase 17 row + open follow-up |
| `AGENTS.md` | Plans status table: phase 17 |

Optional (nice if cheap): a tiny Vala or pytest-free unit check is not
required in v1; prefer extracting RMS logic so a later unit test can
feed synthetic silence/speech buffers. Manual checklist below is enough
for acceptance.

## GSettings keys

```xml
<key name="dictation-auto-stop" type="b">
  <default>false</default>
  <summary>Stop dictation after a pause in speech</summary>
  <description>When true, dictation ends automatically after
  dictation-auto-stop-pause-ms of silence (including if the user never
  speaks). Record mode is unaffected. When false, dictation stops only
  via toggle, Stop, or shortcut.</description>
</key>
<key name="dictation-auto-stop-pause-ms" type="i">
  <default>1200</default>
  <summary>Silence duration before dictation auto-stops (ms)</summary>
  <description>How long speech must stay below the internal energy
  threshold before dictation stops. Intended range 500–5000. Only used
  when dictation-auto-stop is true.</description>
</key>
```

Place next to the other `dictation-*` keys in
`data/im.apodaca.owlet.gschema.xml` (~24–48).

Clamp the SpinRow (and optionally `set_int` path) to 500–5000 so bad
values cannot brick the session.

## Preferences UI

Append to the Feedback group in `src/ui/preferences.ui` after
`dictation_hud_row`:

```xml
<child>
  <object class="AdwSwitchRow" id="dictation_auto_stop_row">
    <property name="title" translatable="yes">Auto-stop after pause</property>
    <property name="subtitle" translatable="yes">End dictation when you stop speaking for a while</property>
  </object>
</child>
<child>
  <object class="AdwSpinRow" id="dictation_auto_stop_pause_row">
    <property name="title" translatable="yes">Pause duration</property>
    <property name="subtitle" translatable="yes">Milliseconds of silence before dictation stops</property>
    <property name="adjustment">
      <object class="GtkAdjustment">
        <property name="lower">500</property>
        <property name="upper">5000</property>
        <property name="step-increment">100</property>
        <property name="page-increment">500</property>
      </object>
    </property>
  </object>
</child>
```

Bind in `populate_general_page`:

- `settings.bind ("dictation-auto-stop", dictation_auto_stop_row, "active", …)`
- Spin ↔ `dictation-auto-stop-pause-ms` via notify/`set_int` (same pattern
  as `cpu_threads_row` in `preferences.vala` ~166–170)
- `dictation_auto_stop_pause_row.sensitive` follows the switch (bind
  `active` → `sensitive` or update in the switch notify)

Live GSettings reads in the window (or change notifications) so toggling
the pref mid-session does not require restart.

## Window wiring details

1. Construct `Owlet.SilenceDetector` beside `sound_feedback` / `hud`.
2. On `start_dictation` when entering dictating (including mid-Record
   piggyback ~442–450): `silence_detector.reset()` and refresh
   `pause_ms` from settings.
3. On `clear_dictation_state` (~521–526): `silence_detector.reset()`.
4. In `on_chunk` (~356–369), after the existing feed/append work:

   - If `!dictating` or `!settings.get_boolean ("dictation-auto-stop")`
     → return (do not observe).
   - Update `silence_detector.pause_ms` from settings (or cache on
     start + settings `changed` handler).
   - If `observe(samples)` returns true →
     `GLib.Idle.add (() => { stop_dictation (); return false; })`.
     Do **not** call GTK/`stop_dictation` on the GST thread.

5. Deduplicate: detector returns true once; `stop_dictation` is
   idempotent when `!dictating`; avoid stacking Idle sources (flag or
   detector state).

6. Do **not** wire auto-stop into `on_stop` / Record. USR2 global stop
   for Record remains unchanged.

## Edge cases

- **250 ms foreground delay:** No chunks yet → no auto-stop until mic
  live (correct).
- **Cancel during delay:** Existing `stop_dictation` path; detector idle.
- **Already stopping:** Further silence chunks ignored until next
  `reset()`.
- **Noisy rooms:** Fixed RMS may false-hold or false-stop; v1 accepts
  that — threshold tuning + pause slider are the levers; no adaptive
  noise floor in v1.
- **Batch vs streaming:** Auto-stop only ends capture; finalize path
  unchanged (`on_recording_stopped` / batch).
- **HUD / sound feedback:** Unchanged — they already follow
  `stop_dictation` / finalize.

## Out of scope (v1)

- Auto-stop for Record mode
- Continuous listen / “commit and keep listening”
- Model-side VAD / Whisper `no_speech` binding
- Preferences energy-threshold slider
- Adaptive noise-floor calibration
- Shortcuts dialog row (phase 8 territory if listed later)

## Acceptance criteria

- [ ] Pref default off — dictation behavior unchanged until enabled
- [ ] Pref on + Dictate + silence ≥ pause → session ends like manual
      Dictate off (tone if sound-feedback on, text typed, HUD hidden,
      idle)
- [ ] Pref on + Dictate + never speak → stops after same pause
- [ ] Brief pauses shorter than configured duration do not stop
- [ ] Pure Record never auto-stops
- [ ] Pause SpinRow clamped 500–5000; sensitive only when switch on
- [ ] Changing pause / enabling mid-session takes effect without restart
- [ ] No crash / GTK-from-wrong-thread warnings on auto-stop
- [ ] `meson test -C build --suite unit` passes (schema defaults)

## Manual test notes

1. Enable Auto-stop; set pause to 1200 ms; Dictate into a text field;
   speak a sentence; stop talking → should finalize ~1.2 s later.
2. Same with pause 500 vs 3000 — feel the difference; mid-thought
   pauses under the setting should not cut off.
3. Start Dictate, say nothing → ends after pause; restart with shortcut
   works.
4. Record only with pref on → stays open until Stop.
5. Pref off → silence never ends dictation.
6. Global shortcut + tray Dictate with HUD: auto-stop clears HUD and
   types finals as today.

## Worktrunk

```bash
wt switch --create phase-17-dictation-silence-auto-stop --no-cd --format json -y
cd .worktrees/phase-17-dictation-silence-auto-stop
git submodule update --init --recursive
meson setup build && ninja -C build
```

## Commit sequence

1. `SilenceDetector` + meson + GSettings keys + gsettings unit defaults.
2. Window `on_chunk` wiring + `stop_dictation` Idle path + reset points.
3. Preferences Feedback SwitchRow + SpinRow binds.

## Related

- Dictation stop path: `src/window.vala` `stop_dictation` / `on_chunk`
- Recorder PCM: `src/services/recorder.vala` `chunk_ready`
- Phase 11 sound feedback / Phase 13 HUD — stop/finalize side effects
  already correct if auto-stop calls `stop_dictation()`