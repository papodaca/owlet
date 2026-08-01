/* dictation-hud.vala
 *
 * Always-on-top, non-focus-stealing OSD for background dictation
 * (global shortcut / tray). Soft-fails when X11/XWayland is unavailable.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class Owlet.DictationHud : GLib.Object {
    public bool available { get; private set; }
    public bool visible { get; private set; }

    private Owlet.DictationHudShim.Native? native_hud;

    public DictationHud () {
        native_hud = Owlet.DictationHudShim.Native.create ();
        available = native_hud != null;
        if (!available)
            warning ("Dictation HUD unavailable (no X11/XWayland DISPLAY)");
    }

    public void show () {
        if (native_hud == null)
            return;
        native_hud.show ();
        visible = true;
    }

    public void hide () {
        if (native_hud == null)
            return;
        native_hud.hide ();
        visible = false;
    }

    public void set_text (string text) {
        if (native_hud == null || !visible)
            return;
        native_hud.set_text (text);
    }

    public override void dispose () {
        if (native_hud != null) {
            native_hud.hide ();
            // Compact class: drop the owned reference so free_function runs.
            native_hud = null;
        }
        visible = false;
        base.dispose ();
    }
}