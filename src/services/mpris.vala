/* mpris.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * MPRIS2 exporter for document-reading transport. GNOME and KDE route
 * hardware play/pause keys to org.mpris.MediaPlayer2.Player. Objects
 * are registered via Vala [DBus] classes + register_object<T>(), the
 * same GIO path as Tray. Vala getters do not emit PropertiesChanged,
 * so PlaybackStatus / Metadata updates are sent by hand.
 */

public class Owlet.MprisService : GLib.Object {
    public signal void play_requested ();
    public signal void pause_requested ();
    public signal void play_pause_requested ();
    public signal void raise_requested ();

    private const string BUS_NAME = "org.mpris.MediaPlayer2.im.apodaca.owlet";
    private const string OBJECT_PATH = "/org/mpris/MediaPlayer2";
    private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";

    private GLib.DBusConnection? conn = null;
    private Root? root = null;
    private Player? player_obj = null;
    private uint owner_id = 0;
    private uint root_reg_id = 0;
    private uint player_reg_id = 0;
    private bool want_owned = false;

    private string _title = "";
    private uint _track_serial = 1;
    private Owlet.PlayerState _state = Owlet.PlayerState.STOPPED;

    public void export (string title, Owlet.PlayerState state) {
        bool already = (owner_id != 0);
        bool title_changed = (_title != title);
        if (already && title_changed)
            _track_serial++;
        _title = title;
        bool status_changed = (_state != state);
        _state = state;
        want_owned = true;

        if (!already) {
            owner_id = GLib.Bus.own_name (
                GLib.BusType.SESSION,
                BUS_NAME,
                GLib.BusNameOwnerFlags.NONE,
                on_bus_acquired,
                on_name_acquired,
                on_name_lost);
            return;
        }

        if (!title_changed && !status_changed)
            return;

        var changed = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
        if (title_changed)
            changed.add ("{sv}", "Metadata", build_metadata ());
        if (status_changed)
            changed.add ("{sv}", "PlaybackStatus",
                         new GLib.Variant.string (playback_status_string ()));
        emit_player_changes (changed);
    }

    public void release () {
        want_owned = false;
        unregister_objects ();
        if (owner_id != 0) {
            GLib.Bus.unown_name (owner_id);
            owner_id = 0;
        }
        conn = null;
    }

    private string track_title () {
        return (_title != "") ? _title : "Document";
    }

    private string track_object_path () {
        return "/im/apodaca/owlet/Track/%u".printf (_track_serial);
    }

    private string playback_status_string () {
        switch (_state) {
        case Owlet.PlayerState.PLAYING:
            return "Playing";
        case Owlet.PlayerState.PAUSED:
            return "Paused";
        case Owlet.PlayerState.STOPPED:
        default:
            return "Stopped";
        }
    }

    private GLib.HashTable<string, GLib.Variant> metadata_table () {
        var table = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
        table.insert ("mpris:trackid",
                      new GLib.Variant.object_path (track_object_path ()));
        table.insert ("xesam:title", new GLib.Variant.string (track_title ()));
        return table;
    }

    private GLib.Variant build_metadata () {
        var builder = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
        metadata_table ().foreach ((key, val) => {
            builder.add ("{sv}", key, val);
        });
        return builder.end ();
    }

    private delegate void QueuedAction ();

    private void queue_on_main (owned QueuedAction action) {
        Idle.add (() => {
            action ();
            return GLib.Source.REMOVE;
        });
    }

    private void queue_play () {
        queue_on_main (() => { play_requested (); });
    }

    private void queue_pause () {
        queue_on_main (() => { pause_requested (); });
    }

    private void queue_play_pause () {
        queue_on_main (() => { play_pause_requested (); });
    }

    private void queue_raise () {
        queue_on_main (() => { raise_requested (); });
    }

    private void on_bus_acquired (GLib.DBusConnection connection, string name) {
        if (!want_owned)
            return;

        conn = connection;
        try {
            root = new Root (this);
            player_obj = new Player (this);
            root_reg_id = connection.register_object (OBJECT_PATH, root);
            player_reg_id = connection.register_object (OBJECT_PATH, player_obj);
        } catch (GLib.Error e) {
            warning ("MPRIS register failed: %s", e.message);
            unregister_objects ();
        }
    }

    private void on_name_acquired (GLib.DBusConnection connection, string name) {
        if (!want_owned)
            release ();
    }

    private void on_name_lost (GLib.DBusConnection? connection, string name) {
        unregister_objects ();
        conn = null;
        if (owner_id != 0) {
            var id = owner_id;
            owner_id = 0;
            GLib.Bus.unown_name (id);
        }
        if (want_owned)
            warning ("MPRIS name lost: %s", name);
    }

    private void unregister_objects () {
        if (conn != null) {
            if (root_reg_id != 0) {
                conn.unregister_object (root_reg_id);
                root_reg_id = 0;
            }
            if (player_reg_id != 0) {
                conn.unregister_object (player_reg_id);
                player_reg_id = 0;
            }
        }
        root = null;
        player_obj = null;
    }

    private void emit_player_changes (GLib.VariantBuilder changed) {
        if (conn == null)
            return;

        var invalidated = new GLib.VariantBuilder (new GLib.VariantType ("as"));
        try {
            conn.emit_signal (
                null,
                OBJECT_PATH,
                "org.freedesktop.DBus.Properties",
                "PropertiesChanged",
                new GLib.Variant ("(sa{sv}as)",
                    PLAYER_IFACE, changed, invalidated));
        } catch (GLib.Error e) {
            warning ("MPRIS PropertiesChanged failed: %s", e.message);
        }
    }

    [DBus (name = "org.mpris.MediaPlayer2")]
    private class Root : GLib.Object {
        private weak MprisService service;

        public Root (MprisService service) {
            this.service = service;
        }

        [DBus (name = "Raise")]
        public void raise () throws GLib.Error {
            service.queue_raise ();
        }

        [DBus (name = "Quit")]
        public void quit () throws GLib.Error {
        }

        [DBus (name = "CanQuit")]
        public bool can_quit { get { return false; } }

        [DBus (name = "CanRaise")]
        public bool can_raise { get { return true; } }

        [DBus (name = "HasTrackList")]
        public bool has_track_list { get { return false; } }

        [DBus (name = "Identity")]
        public string identity { owned get { return "Owlet"; } }

        [DBus (name = "DesktopEntry")]
        public string desktop_entry { owned get { return "im.apodaca.owlet"; } }

        [DBus (name = "SupportedUriSchemes")]
        public string[] supported_uri_schemes { owned get { return new string[0]; } }

        [DBus (name = "SupportedMimeTypes")]
        public string[] supported_mime_types { owned get { return new string[0]; } }
    }

    [DBus (name = "org.mpris.MediaPlayer2.Player")]
    private class Player : GLib.Object {
        private weak MprisService service;

        public Player (MprisService service) {
            this.service = service;
        }

        [DBus (name = "Next")]
        public void next () throws GLib.Error {
        }

        [DBus (name = "Previous")]
        public void previous () throws GLib.Error {
        }

        [DBus (name = "Pause")]
        public void pause () throws GLib.Error {
            service.queue_pause ();
        }

        [DBus (name = "PlayPause")]
        public void play_pause () throws GLib.Error {
            service.queue_play_pause ();
        }

        [DBus (name = "Stop")]
        public void stop () throws GLib.Error {
        }

        [DBus (name = "Play")]
        public void play () throws GLib.Error {
            service.queue_play ();
        }

        [DBus (name = "Seek")]
        public void seek (int64 offset) throws GLib.Error {
        }

        [DBus (name = "SetPosition")]
        public void set_position (GLib.ObjectPath track_id, int64 position) throws GLib.Error {
        }

        [DBus (name = "OpenUri")]
        public void open_uri (string uri) throws GLib.Error {
        }

        [DBus (name = "PlaybackStatus")]
        public string playback_status {
            owned get { return service.playback_status_string (); }
        }

        [DBus (name = "Rate")]
        public double rate {
            get { return 1.0; }
            set { }
        }

        [DBus (name = "Metadata")]
        public GLib.HashTable<string, GLib.Variant> metadata {
            owned get { return service.metadata_table (); }
        }

        [DBus (name = "Volume")]
        public double volume {
            get { return 1.0; }
            set { }
        }

        [DBus (name = "Position")]
        public int64 position { get { return 0; } }

        [DBus (name = "MinimumRate")]
        public double minimum_rate { get { return 1.0; } }

        [DBus (name = "MaximumRate")]
        public double maximum_rate { get { return 1.0; } }

        [DBus (name = "CanGoNext")]
        public bool can_go_next { get { return false; } }

        [DBus (name = "CanGoPrevious")]
        public bool can_go_previous { get { return false; } }

        [DBus (name = "CanPlay")]
        public bool can_play { get { return true; } }

        [DBus (name = "CanPause")]
        public bool can_pause { get { return true; } }

        [DBus (name = "CanSeek")]
        public bool can_seek { get { return false; } }

        [DBus (name = "CanControl")]
        public bool can_control { get { return true; } }

        [DBus (name = "Seeked")]
        public signal void seeked (int64 position);
    }
}
