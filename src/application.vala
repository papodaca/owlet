/* application.vala
 *
 * Copyright 2026 Ethan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class Owlet.Application : Adw.Application {
    private GLib.Settings? _settings = null;
    private Owlet.GlobalShortcuts? _shortcuts = null;
    private Owlet.Tray? _tray = null;
    private Owlet.MprisService? _mpris = null;
    // Path to the pidfile written for the owlet-signal fallback helper.
    // Null when no pidfile was written (XDG_RUNTIME_DIR unwritable, or
    // the process is a transient forwarding instance). Cleared in
    // shutdown.
    private string? _pidfile = null;

    public Application () {
        Object (
            application_id: "im.apodaca.owlet",
            flags: ApplicationFlags.DEFAULT_FLAGS,
            resource_base_path: "/im/apodaca/owlet"
        );
    }

    construct {
        ActionEntry[] action_entries = {
            { "about", this.on_about_action },
            { "preferences", this.on_preferences_action },
            { "shortcuts", this.on_shortcuts_action },
            { "quit", this.quit }
        };
        this.add_action_entries (action_entries, this);

        // Apply all customizable shortcuts from GSettings on startup
        // and re-apply live whenever a shortcut-* key changes. The
        // PreferencesDialog.ShortcutRow fires the write to GSettings;
        // the changed:: signal here propagates the change to the
        // application immediately (per plan § Shortcuts page: "no
        // restart required").
        apply_shortcuts ();
        settings.changed.connect ((changed_key) => {
            if (changed_key.has_prefix ("shortcut-"))
                apply_shortcuts ();
            else if (changed_key == "close-to-tray")
                on_close_to_tray_changed ();
        });
    }

    public unowned GLib.Settings settings {
        get {
            if (_settings == null)
                _settings = new GLib.Settings ("im.apodaca.owlet");
            return _settings;
        }
    }

    private Owlet.ModelDownloader? _model_downloader = null;
    public Owlet.ModelDownloader model_downloader {
        get {
            if (_model_downloader == null)
                _model_downloader = new Owlet.ModelDownloader ();
            return _model_downloader;
        }
    }

    private Owlet.VoiceModels? _voice_models = null;
    public Owlet.VoiceModels voice_models {
        get {
            if (_voice_models == null)
                _voice_models = new Owlet.VoiceModels (model_downloader);
            return _voice_models;
        }
    }

    /**
     * Re-apply all customizable accelerators from GSettings. Called at
     * startup and whenever a shortcut-* key changes. win.* actions
     * (record/stop/insert/dictate) are routed to the application; the
     * currently-focused window picks them up automatically.
     */
    public void apply_shortcuts () {
        var s = settings;
        // Each action takes a 1-element array of the GSettings value,
        // or an empty array (which removes any existing binding) when
        // the user has cleared the shortcut. The accel_array helper
        // handles the empty-string case.
        set_accels_for_action ("app.quit",
            accel_array (s.get_string ("shortcut-quit")));
        set_accels_for_action ("app.preferences",
            accel_array (s.get_string ("shortcut-prefs")));
        set_accels_for_action ("app.shortcuts",
            accel_array (s.get_string ("shortcut-shortcuts")));
        set_accels_for_action ("win.record",
            accel_array (s.get_string ("shortcut-record")));
        set_accels_for_action ("win.stop",
            accel_array (s.get_string ("shortcut-stop")));
        set_accels_for_action ("win.insert",
            accel_array (s.get_string ("shortcut-insert")));
        set_accels_for_action ("win.dictate",
            accel_array (s.get_string ("shortcut-dictate")));
    }

    // Wrap a single GSettings accel string into the array shape that
    // set_accels_for_action expects. Empty string → empty array (which
    // removes any existing binding for the action).
    private static string[] accel_array (string accel) {
        if (accel == null || accel == "")
            return new string[0];
        return new string[] { accel };
    }

    /* ----------------------------------------------------------------- */
    /* Global shortcuts: portal (preferred) + Unix-signal fallback       */
    /* ----------------------------------------------------------------- */

    // SIGRTMIN is a function-based macro on glibc and a constant on
    // musl; posix.vapi has no binding. The shim in src/vapi/signal-shim.c
    // exposes it; the +1 offset is the first user-usable realtime
    // signal (glibc reserves SIGRTMIN itself).
    [CCode (cname = "owlet_sigrtmin", cheader_filename = "signal-shim.h")]
    private static extern int owlet_sigrtmin ();

    public override void startup () {
        base.startup ();

        // Preferred: xdg-desktop-portal GlobalShortcuts. init is async
        // and best-effort — available flips to false on any failure,
        // leaving the Unix-signal fallback as the active path.
        _shortcuts = new Owlet.GlobalShortcuts ();
        _shortcuts.shortcut_activated.connect (on_global_shortcut_activated);
        _shortcuts.init.begin ();

        // Fallback: the owlet-signal helper sends these. Registered in
        // startup so they're live before the first window appears.
        // Source.CONTINUE keeps the source installed for the process
        // lifetime (a one-shot would miss later signals).
        GLib.Unix.signal_add (Posix.Signal.USR1, () => {
            on_global_toggle ();
            return GLib.Source.CONTINUE;
        });
        GLib.Unix.signal_add (Posix.Signal.USR2, () => {
            on_global_stop ();
            return GLib.Source.CONTINUE;
        });
        GLib.Unix.signal_add (owlet_sigrtmin () + 1, () => {
            on_global_insert ();
            return GLib.Source.CONTINUE;
        });

        write_pidfile ();

        // Tray is constructed once; shown only when close-to-tray hides
        // the window. Recording state is cached even while hidden.
        _tray = new Owlet.Tray ();
        _tray.show_requested.connect (on_tray_show);
        _tray.dictate_requested.connect (on_tray_dictate);
        _tray.quit_requested.connect (() => { this.quit (); });

        // MPRIS is constructed once; the well-known name is owned only
        // while a readable document is on the content page.
        _mpris = new Owlet.MprisService ();
        _mpris.play_requested.connect (on_mpris_play);
        _mpris.pause_requested.connect (on_mpris_pause);
        _mpris.play_pause_requested.connect (on_mpris_play_pause);
        _mpris.raise_requested.connect (on_tray_show);
    }

    public override void shutdown () {
        if (_mpris != null)
            _mpris.release ();
        if (_tray != null)
            _tray.hide ();
        remove_pidfile ();
        base.shutdown ();
    }

    // True once the portal interface is confirmed and bound. Read by
    // the Preferences Shortcuts page to pick between "Bind via portal"
    // and "Install helper script" UI.
    public bool global_shortcuts_available {
        get { return _shortcuts != null && _shortcuts.available; }
    }

    // Driven from the Preferences "Bind via portal" button: create the
    // portal session and ask the user to assign a trigger combo. The
    // shortcut drives the full dictation flow (toggle on = record +
    // stream into the focused window, toggle off = stop + type the
    // final text), so the user-facing description says "dictation".
    public async void bind_global_shortcut () {
        if (_shortcuts == null)
            return;
        yield _shortcuts.bind ("toggle-recording", _("Toggle voice dictation"));
    }

    private void on_global_shortcut_activated (string id) {
        if (id == "toggle-recording")
            on_global_toggle ();
    }

    // Drive background dictation: no minimize, show the HUD OSD, and
    // stream partial transcripts into the focused window; toggle off
    // stops recording, finalizes, and types the final text.
    private void on_global_toggle () {
        (this.active_window as Owlet.Window)?.toggle_dictation_background ();
    }

    private void on_global_stop () {
        (this.active_window as Owlet.Window)?.stop ();
    }

    private void on_global_insert () {
        (this.active_window as Owlet.Window)?.insert ();
    }

    /* ----------------------------------------------------------------- */
    /* Close-to-tray                                                      */
    /* ----------------------------------------------------------------- */

    // Called from Window.close_request after hide(). Exports the SNI
    // tray icon (soft-fails if no StatusNotifierWatcher is present).
    public void request_hide_to_tray () {
        if (_tray != null)
            _tray.show ();
    }

    // Window notifies whenever the mic recording flag flips. Safe to
    // call while the tray is not visible — state is applied on show().
    public void set_tray_recording (bool active) {
        if (_tray != null)
            _tray.set_recording (active);
    }

    private void on_tray_show () {
        var win = this.active_window;
        if (win != null)
            win.present ();
        if (_tray != null)
            _tray.hide ();
    }

    private void on_tray_dictate () {
        (this.active_window as Owlet.Window)?.toggle_dictation_background ();
    }

    public void sync_reader_mpris (bool readable, string title, Owlet.PlayerState state) {
        if (_mpris == null)
            return;
        if (readable)
            _mpris.export (title, state);
        else
            _mpris.release ();
    }

    private Owlet.Window? reader_window () {
        var active = this.active_window as Owlet.Window;
        if (active != null)
            return active;
        foreach (var w in this.get_windows ()) {
            var ow = w as Owlet.Window;
            if (ow != null)
                return ow;
        }
        return null;
    }

    private void on_mpris_play () {
        reader_window ()?.reader_play ();
    }

    private void on_mpris_pause () {
        reader_window ()?.reader_pause ();
    }

    private void on_mpris_play_pause () {
        reader_window ()?.reader_play_pause ();
    }

    // If the user turns close-to-tray off while the window is hidden,
    // restore so they are not stuck without a UI restore path.
    private void on_close_to_tray_changed () {
        if (settings.get_boolean ("close-to-tray"))
            return;
        var win = this.active_window;
        if (win != null && !win.visible)
            win.present ();
        if (_tray != null)
            _tray.hide ();
    }

    // Write $XDG_RUNTIME_DIR/owlet.pid (or /tmp/owlet.pid) so the
    // owlet-signal fallback helper can find this process. XDG_RUNTIME_DIR
    // is 0700 user-owned, so the pidfile isn't world-readable.
    private void write_pidfile () {
        string runtime = GLib.Environment.get_variable ("XDG_RUNTIME_DIR");
        if (runtime == null || runtime == "")
            runtime = "/tmp";
        _pidfile = runtime + "/owlet.pid";
        try {
            GLib.FileUtils.set_contents (_pidfile,
                "%d".printf ((int) Posix.getpid ()));
        } catch (GLib.Error e) {
            warning ("cannot write pidfile %s: %s", _pidfile, e.message);
            _pidfile = null;
        }
    }

    private void remove_pidfile () {
        if (_pidfile == null)
            return;
        try {
            GLib.FileUtils.unlink (_pidfile);
        } catch (GLib.Error e) {
            // Already gone (e.g. a second instance overwrote then
            // cleared it) — nothing to do.
        }
        _pidfile = null;
    }

    public override void activate () {
        base.activate ();
        var win = this.active_window;
        if (win != null) {
            // Re-launch / D-Bus activate while tray-hidden: restore and
            // tear down the tray icon.
            win.present ();
            if (_tray != null)
                _tray.hide ();
        } else {
            win = new Owlet.Window (this);
            win.present ();
        }
    }

    private void on_about_action () {
        string[] developers = { "Ethan" };
        var about = new Adw.AboutDialog () {
            application_name = "Owlet",
            application_icon = "im.apodaca.owlet",
            developer_name = "Ethan",
            translator_credits = _("translator-credits"),
            version = "0.1.0",
            developers = developers,
            copyright = "© 2026 Ethan",
        };

        about.present (this.active_window);
    }

    private void on_preferences_action () {
        var prefs = new Owlet.PreferencesDialog (this, this.active_window);
        prefs.present (this.active_window);
    }

    private void on_shortcuts_action () {
        var builder = new Gtk.Builder.from_resource ("/im/apodaca/owlet/shortcuts-dialog.ui");
        var dialog = (Adw.ShortcutsDialog) builder.get_object ("shortcuts_dialog");
        dialog.present (this.active_window);
    }
}
