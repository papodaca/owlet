# Phase 13 — Dictation HUD (global shortcut / tray)

## Goal

When dictation is started from the **global shortcut** or **tray Dictate**:

1. **Do not minimize** Kaki (already backgrounded in the common case).
2. Show an **always-on-top, non-focus-stealing OSD** that mirrors streaming
   transcript text as it arrives.
3. Keep existing sinks unchanged: **transcript buffer** + **keystroke
   injection** — the HUD is one more feedback point, not a replacement.

In-window Dictate stays as today: **minimize + 250 ms delay, no HUD**.

## Motivation

Global / tray activation is meant for dictating into another app while Kaki
is already in the background (or hidden to tray). Minimizing is unnecessary
and can be disruptive. Users still need a visible live transcript without
bringing the main window forward.

## Decisions (locked)

| Choice | Decision |
| --- | --- |
| Global shortcut | Overlay HUD, **no** minimize |
| Tray Dictate | Same as global shortcut |
| In-window Dictate | Keep today’s minimize + 250 ms delay; **no** HUD |
| GNOME Wayland | XWayland override-redirect via **in-process Xlib HUD** |
| Backend | In-process Xlib + Cairo/Pango (not Gtk.Window, not subprocess, not gtk4-layer-shell) |
| HUD UX | Bottom-center translucent OSD, red recording dot, streaming text (show **tail** if long), click-through, hide when dictation ends |
| Prefs toggle | Feedback → “Dictation overlay” (`dictation-hud`, default **on**) |
| X11 unavailable | Soft-fail: warn, continue dictation without HUD |

## Why not Gtk.Window / layer-shell

GTK4’s display backend is process-wide. Under GNOME Wayland the main app is
on Wayland; a `Gtk.Window` cannot be forced onto XWayland alone in-process.
`gtk4-layer-shell` needs `wlr-layer-shell`, which Mutter does not implement.
An in-process override-redirect X11 window (native X11 or via XWayland)
gives always-on-top + no focus steal on GNOME and other desktops without a
new portal or helper process.

## Current behavior (baseline)

- Global shortcut and tray both call `Kaki.Window.toggle_dictation()` →
  `on_dictate_toggle()` → `start_dictation()` (`src/application.vala`,
  `src/window.vala`).
- `start_dictation()` always calls `this.minimize()` then a 250 ms timeout
  before `recorder.start()`.
- Partials/finals update `transcript_view` and, when dictating,
  `type_dictation()` (`on_partial_text` / `on_final_text`).
- No existing overlay/HUD; no X11 / Xext build deps today.

## Architecture

```
Global shortcut / tray Dictate
        │
        ▼
Window.toggle_dictation_background()
        │
        ├─ start: no minimize, DictationHud.show(), recorder.start() immediately
        └─ stop:  same finalize path as today + DictationHud.hide()

In-window win.dictate / Dictate button
        │
        ▼
Window.toggle_dictation() → start_dictation(foreground)
        │
        └─ minimize + 250 ms delay + recorder.start()  (unchanged; no HUD)

partial_text / final_text / batch final
        │
        ├─ transcript_view buffer          (unchanged)
        ├─ type_dictation() if dictating   (unchanged)
        └─ DictationHud.set_text() if HUD active
```

## Behavior matrix

| Entry point | Minimize? | HUD? | Transcript + keystrokes |
| --- | --- | --- | --- |
| Global shortcut | No | Yes (if prefs on) | Yes |
| Tray → Dictate | No | Yes (if prefs on) | Yes |
| In-window Dictate | Yes (250 ms) | No | Yes |

| Event | HUD |
| --- | --- |
| Background dictation start | `show()` + recording indicator |
| Partial / final / batch text | `set_text(text)` (tail-visible if ellipsized) |
| Stop / finalize / batch done | `hide()` |
| Recorder start failure / error clearing dictating | `hide()`; keep existing `present()` + toast on error |
| Pure Wayland without XWayland | No HUD; dictation still runs |

## Files to create

### `src/services/dictation-hud.vala`

```vala
public class Kaki.DictationHud : GLib.Object {
    public bool available { get; private set; }

    public void show ();
    public void hide ();
    public void set_text (string text);
}
```

Implementation notes:

- `XOpenDisplay(null)` — fail → `available = false`, all methods no-op.
- Override-redirect window; `_NET_WM_STATE_ABOVE`; skip taskbar/pager.
- Draw with Cairo + Pango: dark translucent rounded rect, padding, red
  recording indicator, wrapped text ellipsized from the **start** so the
  live tail stays visible.
- Click-through via empty ShapeInput region (`Xext` shape) so the HUD never
  steals pointer or focus.
- Never call `XSetInputFocus`; never use a GTK window for the OSD.
- Bottom-center of the default/primary screen; ~60% screen width max.
- Own the X window lifecycle across show/hide; destroy on `dispose`.

Add a C shim under `src/vapi/` (`dictation-hud-shim.c` / `.h` / `.vapi`) —
Vala Xlib bindings lack Xext Shape, and X11 deps must stay off the Vala
`--pkg` line (see meson notes below).

## Files to modify

### `src/window.vala`

- Keep `toggle_dictation()` for the in-window action path.
- Add `toggle_dictation_background()` for Application global/tray handlers
  (same on/off semantics: `dictate_btn.active`, `dictating`, `last_typed`).
- Refactor `start_dictation()` to take a launch mode (foreground vs
  background):
  - **Foreground:** minimize + 250 ms timeout (today).
  - **Background:** no minimize; `maybe_show_dictation_hud()` (respects
    `dictation-hud` GSettings); start recorder **immediately**.
- In `on_partial_text` / `on_final_text` / batch dictation success: if HUD
  active, `hud.set_text(text)` after existing buffer/type updates.
- Hide HUD whenever dictation clears (stop, finalize, batch done, start
  failure, recorder error, dispose).
- Construct/own a `DictationHud` beside `keystroke` / `sound_feedback`.

### GSettings + Preferences

- Schema key `dictation-hud` (boolean, default `true`).
- Feedback page switch “Dictation overlay” bound to the key.
- When false: background dictation still runs; no OSD.

### `src/application.vala`

- `on_global_toggle()` and `on_tray_dictate()` call
  `toggle_dictation_background()` instead of `toggle_dictation()`.
- Update comments that still say the global toggle “minimizes Kaki”.

### `src/meson.build`

- Add `dictation-hud.vala` to `kaki_sources`.
- Build `dictation-hud-shim.c` as a **C static library** with deps
  `glib-2.0`, `x11`, `xext`, `pangocairo`, `cairo-xlib`, then
  `link_with` it from `kaki`. Do **not** put those X11/Cairo pkgs on
  `kaki_deps` — Meson would pass them as `--pkg` to `valac`, and there
  is no system `xext.vapi` / `cairo-xlib.vapi`.
- Expose the hand-written `dictation-hud-shim.vapi` via
  `valac.find_library('dictation-hud-shim', …)` only.

### Packaging (`packaging/…`, phase 12)

- Ensure runtime/build depends include `libx11` / `libxext` (and pango/cairo
  if not already implied). Document that the HUD needs X11 or XWayland.

## Edge cases

- **Kaki focused + global shortcut:** Still no minimize (locked). Keystrokes
  may land in Kaki if it retains focus — acceptable for v1; a later
  heuristic can minimize only when `is_active`.
- **Close-to-tray (hidden window):** Background path is natural; HUD still
  shows; no minimize.
- **In-window Dictate while already recording:** Unchanged (mark dictating
  only); no HUD.
- **Cancel during 250 ms foreground delay:** Unchanged; HUD not involved.

## Out of scope (v1)

- gtk4-layer-shell / wlr-layer-shell path
- Separate X11 helper subprocess
- Changing insert / test-keystroke minimize behavior
- Multi-monitor placement beyond default/primary bottom-center
- Auto-minimize when Kaki is focused during background launch

## Testing

Automated coverage will be thin (display-server OSD). Manual checklist:

1. Global shortcut start/stop with another app focused → no Kaki minimize;
   HUD appears; text streams in HUD + target app + transcript.
2. Tray Dictate → same as (1).
3. In-window Dictate → still minimizes; no HUD.
4. Stop / finalize / recorder error dismisses HUD.
5. Smoke on GNOME Wayland (XWayland) and one X11 session.
6. Clicks pass through the HUD onto the app below.
7. Soft-fail path: break X11 (`DISPLAY=` unset in a nested test if
   practical) → warning + dictation without HUD.
8. Preferences → Feedback → turn off “Dictation overlay” → global/tray
   dictation runs with no HUD; turn back on → HUD returns.

## Commit sequence

1. `DictationHud` + meson x11/xext wiring (show/hide/set_text smoke).
2. Window launch-mode split + Application global/tray wiring + text sink.
3. Packaging dep note / Arch depends bump if needed.