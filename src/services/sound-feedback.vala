/* sound-feedback.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Short bundled tones for recording start/stop. Gated by the
 * sound-feedback GSettings key (default true). Uses Gtk.MediaFile so
 * no extra dependency beyond GTK4; the MediaFile ref is held until
 * playback ends (or replaced on the next play) so GC does not cut
 * the tone short.
 */

public class Kaki.SoundFeedback : GLib.Object {
    private GLib.Settings settings;
    // Strong ref to the in-flight MediaFile. Replaced on each play so
    // overlapping rapid toggles keep at most one tone alive (latest
    // wins). Cleared when the stream reports ended or error.
    private Gtk.MediaFile? current = null;

    public SoundFeedback (GLib.Settings settings) {
        this.settings = settings;
    }

    public void play_start () {
        play ("/org/kaki/app/sounds/start.ogg");
    }

    public void play_stop () {
        play ("/org/kaki/app/sounds/stop.ogg");
    }

    private void play (string resource_path) {
        if (!settings.get_boolean ("sound-feedback"))
            return;

        // Drop any previous tone so we never hold two streams.
        if (current != null) {
            current.pause ();
            current = null;
        }

        Gtk.MediaFile media;
        try {
            media = Gtk.MediaFile.for_resource (resource_path);
        } catch (GLib.Error e) {
            // for_resource does not throw in practice, but keep a soft
            // fail path if a future binding changes.
            warning ("Sound feedback: failed to load %s: %s",
                     resource_path, e.message);
            return;
        }

        if (media == null) {
            warning ("Sound feedback: missing resource %s", resource_path);
            return;
        }

        current = media;

        // Release the ref once playback finishes or fails so we do not
        // accumulate MediaFile instances across a long session.
        ulong ended_id = 0;
        ulong error_id = 0;
        ended_id = media.notify["ended"].connect (() => {
            if (!media.ended)
                return;
            if (current == media)
                current = null;
            media.disconnect (ended_id);
            if (error_id != 0)
                media.disconnect (error_id);
        });
        error_id = media.notify["error"].connect (() => {
            unowned GLib.Error? err = media.error;
            if (err != null)
                warning ("Sound feedback: playback error for %s: %s",
                         resource_path, err.message);
            if (current == media)
                current = null;
            media.disconnect (error_id);
            if (ended_id != 0)
                media.disconnect (ended_id);
        });

        // set_playing queues playback for when the stream becomes
        // prepared (resource load is async).
        media.set_playing (true);
    }
}
