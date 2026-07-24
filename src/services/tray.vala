/* tray.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Hand-rolled StatusNotifierItem + com.canonical.dbusmenu over GIO.
 * No ayatana/appindicator dependency — GTK4-safe path used by KDE,
 * XFCE, Cinnamon, Waybar, and GNOME with an AppIndicator extension.
 *
 * Conceptually follows libsni-exporter / blueman SNI exporters; kept
 * minimal for Kaki (flat Show / Dictate / Quit menu, theme IconName
 * swap for the recording indicator).
 *
 * Objects are exported via Vala [DBus] classes + register_object<T>(),
 * which is the supported GIO registration path in Vala (the C vtable
 * form of register_object is not bound).
 */

public class Kaki.Tray : GLib.Object {
    public signal void show_requested ();
    public signal void dictate_requested ();
    public signal void quit_requested ();

    public bool visible { get; private set; default = false; }

    // Manual getter — a `recording { get; private set; }` property would
    // generate kaki_tray_set_recording and collide with set_recording().
    private bool _recording = false;
    public bool recording { get { return _recording; } }

    private const string WATCHER_BUS = "org.kde.StatusNotifierWatcher";
    private const string WATCHER_PATH = "/StatusNotifierWatcher";
    private const string WATCHER_IFACE = "org.kde.StatusNotifierWatcher";
    private const string ITEM_PATH = "/StatusNotifierItem";
    private const string MENU_PATH = "/MenuBar";
    private const string IDLE_ICON = "org.kaki.app";
    private const string RECORDING_ICON = "org.kaki.app-recording";

    // Flat menu ids (root is always 0; children start at 1).
    private const int MENU_SHOW = 1;
    private const int MENU_DICTATE = 2;
    private const int MENU_QUIT = 3;

    private GLib.DBusConnection? conn = null;
    private Item? item = null;
    private Menu? menu = null;
    private uint item_reg_id = 0;
    private uint menu_reg_id = 0;
    private uint watcher_watch_id = 0;
    private uint menu_revision = 1;
    private string icon_name = IDLE_ICON;
    private string tooltip_title = "Kaki";

    public void show () {
        if (visible)
            return;

        apply_recording_visuals ();

        try {
            conn = GLib.Bus.get_sync (GLib.BusType.SESSION);
            item = new Item (this);
            menu = new Menu (this);

            item_reg_id = conn.register_object (ITEM_PATH, item);
            menu_reg_id = conn.register_object (MENU_PATH, menu);

            watcher_watch_id = GLib.Bus.watch_name_on_connection (
                conn, WATCHER_BUS, GLib.BusNameWatcherFlags.NONE,
                on_watcher_appeared, on_watcher_vanished);

            register_with_watcher ();
            visible = true;
        } catch (GLib.Error e) {
            warning ("Tray show failed: %s", e.message);
            teardown_bus ();
        }
    }

    public void hide () {
        if (!visible && conn == null)
            return;
        teardown_bus ();
        visible = false;
    }

    public void set_recording (bool active) {
        if (_recording == active)
            return;
        _recording = active;
        apply_recording_visuals ();
        if (!visible || item == null)
            return;
        item.new_icon ();
        item.new_tool_tip ();
    }

    private void apply_recording_visuals () {
        if (_recording) {
            icon_name = RECORDING_ICON;
            tooltip_title = _("Kaki — Recording");
        } else {
            icon_name = IDLE_ICON;
            tooltip_title = _("Kaki");
        }
    }

    private void teardown_bus () {
        if (watcher_watch_id != 0) {
            GLib.Bus.unwatch_name (watcher_watch_id);
            watcher_watch_id = 0;
        }
        if (conn != null) {
            if (item_reg_id != 0) {
                conn.unregister_object (item_reg_id);
                item_reg_id = 0;
            }
            if (menu_reg_id != 0) {
                conn.unregister_object (menu_reg_id);
                menu_reg_id = 0;
            }
            conn = null;
        }
        item = null;
        menu = null;
    }

    private void on_watcher_appeared (GLib.DBusConnection connection,
                                      string name, string owner) {
        register_with_watcher ();
    }

    private void on_watcher_vanished (GLib.DBusConnection connection,
                                       string name) {
        // Host went away; leave our objects exported so a later
        // watcher can pick us up via on_watcher_appeared.
    }

    private void register_with_watcher () {
        if (conn == null)
            return;
        // Object-path form: watcher uses the caller's unique name + path.
        conn.call.begin (
            WATCHER_BUS, WATCHER_PATH, WATCHER_IFACE,
            "RegisterStatusNotifierItem",
            new GLib.Variant ("(s)", ITEM_PATH),
            null, GLib.DBusCallFlags.NONE, -1, null,
            (obj, res) => {
                try {
                    conn.call.end (res);
                } catch (GLib.Error e) {
                    // Soft-fail: hide still works; restore via activate.
                    warning ("StatusNotifierWatcher unavailable: %s",
                             e.message);
                }
            });
    }

    private static GLib.Variant empty_pixmap () {
        return new GLib.Variant.array (new GLib.VariantType ("(iiay)"), {});
    }

    private static GLib.Variant empty_int_array () {
        return new GLib.Variant.array (new GLib.VariantType ("i"), {});
    }

    private static GLib.Variant empty_string_array () {
        return new GLib.Variant.array (new GLib.VariantType ("s"), {});
    }

    private GLib.Variant build_tooltip () {
        return new GLib.Variant ("(s@a(iiay)ss)",
            "", empty_pixmap (), tooltip_title, "");
    }

    private void dispatch_menu_event (int id, string event_id) {
        if (event_id != "" && event_id != "clicked")
            return;
        switch (id) {
        case MENU_SHOW:
            show_requested ();
            break;
        case MENU_DICTATE:
            dictate_requested ();
            break;
        case MENU_QUIT:
            quit_requested ();
            break;
        }
    }

    private static string menu_label (int id) {
        switch (id) {
        case MENU_SHOW:    return _("Show");
        case MENU_DICTATE: return _("Dictate");
        case MENU_QUIT:    return _("Quit");
        default:           return "";
        }
    }

    private static GLib.Variant? menu_item_property (int id, string name) {
        if (id != MENU_SHOW && id != MENU_DICTATE && id != MENU_QUIT)
            return null;
        switch (name) {
        case "label":
            return new GLib.Variant.string (menu_label (id));
        case "enabled":
            return new GLib.Variant.boolean (true);
        case "visible":
            return new GLib.Variant.boolean (true);
        case "type":
            return new GLib.Variant.string ("");
        case "children-display":
            return new GLib.Variant.string ("");
        default:
            return null;
        }
    }

    private static GLib.Variant build_item_props (int id) {
        var builder = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
        builder.add ("{sv}", "label",
                     new GLib.Variant.string (menu_label (id)));
        builder.add ("{sv}", "enabled", new GLib.Variant.boolean (true));
        builder.add ("{sv}", "visible", new GLib.Variant.boolean (true));
        return builder.end ();
    }

    private static void append_item_props (GLib.VariantBuilder builder, int id) {
        builder.add ("(i@a{sv})", id, build_item_props (id));
    }

    private GLib.Variant build_layout_node (int parent_id, int recursion_depth) {
        if (parent_id != 0) {
            var empty_children = new GLib.VariantBuilder (
                new GLib.VariantType ("av"));
            return new GLib.Variant ("(i@a{sv}av)",
                parent_id, build_item_props (parent_id), empty_children);
        }

        var root_props = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
        root_props.add ("{sv}", "children-display",
                        new GLib.Variant.string ("submenu"));

        var children = new GLib.VariantBuilder (new GLib.VariantType ("av"));
        if (recursion_depth != 0) {
            foreach (int id in new int[] { MENU_SHOW, MENU_DICTATE, MENU_QUIT }) {
                var leaf_children = new GLib.VariantBuilder (
                    new GLib.VariantType ("av"));
                var leaf = new GLib.Variant ("(i@a{sv}av)",
                    id, build_item_props (id), leaf_children);
                children.add_value (new GLib.Variant.variant (leaf));
            }
        }

        return new GLib.Variant ("(i@a{sv}av)",
            0, root_props.end (), children);
    }

    [DBus (name = "org.kde.StatusNotifierItem")]
    private class Item : GLib.Object {
        private weak Tray tray;

        public Item (Tray tray) {
            this.tray = tray;
        }

        [DBus (name = "Category")]
        public string category { owned get { return "ApplicationStatus"; } }

        [DBus (name = "Id")]
        public string id { owned get { return "org.kaki.app"; } }

        [DBus (name = "Title")]
        public string title { owned get { return "Kaki"; } }

        [DBus (name = "Status")]
        public string status { owned get { return "Active"; } }

        [DBus (name = "WindowId")]
        public int window_id { get { return 0; } }

        [DBus (name = "IconThemePath")]
        public string icon_theme_path { owned get { return ""; } }

        [DBus (name = "Menu")]
        public GLib.ObjectPath menu {
            owned get { return new GLib.ObjectPath (MENU_PATH); }
        }

        [DBus (name = "ItemIsMenu")]
        public bool item_is_menu { get { return false; } }

        [DBus (name = "IconName")]
        public string icon_name {
            owned get { return tray.icon_name; }
        }

        [DBus (name = "IconPixmap", signature = "a(iiay)")]
        public GLib.Variant icon_pixmap {
            owned get { return empty_pixmap (); }
        }

        [DBus (name = "OverlayIconName")]
        public string overlay_icon_name { owned get { return ""; } }

        [DBus (name = "OverlayIconPixmap", signature = "a(iiay)")]
        public GLib.Variant overlay_icon_pixmap {
            owned get { return empty_pixmap (); }
        }

        [DBus (name = "AttentionIconName")]
        public string attention_icon_name { owned get { return ""; } }

        [DBus (name = "AttentionIconPixmap", signature = "a(iiay)")]
        public GLib.Variant attention_icon_pixmap {
            owned get { return empty_pixmap (); }
        }

        [DBus (name = "AttentionMovieName")]
        public string attention_movie_name { owned get { return ""; } }

        [DBus (name = "ToolTip", signature = "(sa(iiay)ss)")]
        public GLib.Variant tool_tip {
            owned get { return tray.build_tooltip (); }
        }

        [DBus (name = "ContextMenu")]
        public void context_menu (int x, int y) throws GLib.Error {
            // Host shows dbusmenu via Menu path.
        }

        [DBus (name = "Activate")]
        public void activate (int x, int y) throws GLib.Error {
            tray.show_requested ();
        }

        [DBus (name = "SecondaryActivate")]
        public void secondary_activate (int x, int y) throws GLib.Error {
            tray.show_requested ();
        }

        [DBus (name = "Scroll")]
        public void scroll (int delta, string orientation) throws GLib.Error {
        }

        [DBus (name = "NewTitle")]
        public signal void new_title ();

        [DBus (name = "NewIcon")]
        public signal void new_icon ();

        [DBus (name = "NewAttentionIcon")]
        public signal void new_attention_icon ();

        [DBus (name = "NewOverlayIcon")]
        public signal void new_overlay_icon ();

        [DBus (name = "NewToolTip")]
        public signal void new_tool_tip ();

        [DBus (name = "NewStatus")]
        public signal void new_status (string status);
    }

    [DBus (name = "com.canonical.dbusmenu")]
    private class Menu : GLib.Object {
        private weak Tray tray;

        public Menu (Tray tray) {
            this.tray = tray;
        }

        [DBus (name = "Version")]
        public uint version { get { return 4; } }

        [DBus (name = "TextDirection")]
        public string text_direction { owned get { return "ltr"; } }

        [DBus (name = "Status")]
        public string status { owned get { return "normal"; } }

        [DBus (name = "IconThemePath", signature = "as")]
        public GLib.Variant icon_theme_path {
            owned get { return empty_string_array (); }
        }

        [DBus (name = "GetLayout")]
        public void get_layout (int parent_id, int recursion_depth,
                                 string[] property_names,
                                 out uint revision,
                                 [DBus (signature = "(ia{sv}av)")]
                                 out GLib.Variant layout)
                                 throws GLib.Error {
            revision = tray.menu_revision;
            layout = tray.build_layout_node (parent_id, recursion_depth);
        }

        [DBus (name = "GetGroupProperties")]
        public void get_group_properties (
            [DBus (signature = "ai")] GLib.Variant ids,
            string[] property_names,
            [DBus (signature = "a(ia{sv})")] out GLib.Variant properties)
            throws GLib.Error {
            var builder = new GLib.VariantBuilder (
                new GLib.VariantType ("a(ia{sv})"));
            if (ids.n_children () == 0) {
                append_item_props (builder, MENU_SHOW);
                append_item_props (builder, MENU_DICTATE);
                append_item_props (builder, MENU_QUIT);
            } else {
                for (size_t i = 0; i < ids.n_children (); i++) {
                    int id = ids.get_child_value (i).get_int32 ();
                    if (id == MENU_SHOW || id == MENU_DICTATE || id == MENU_QUIT)
                        append_item_props (builder, id);
                }
            }
            properties = builder.end ();
        }

        [DBus (name = "GetProperty")]
        public GLib.Variant get_item_property (int id, string name)
                                              throws GLib.Error {
            var val = menu_item_property (id, name);
            if (val == null) {
                throw new GLib.DBusError.INVALID_ARGS (
                    "Unknown property");
            }
            return val;
        }

        [DBus (name = "Event")]
        public void event (int id, string event_id, GLib.Variant data,
                            uint timestamp) throws GLib.Error {
            tray.dispatch_menu_event (id, event_id);
        }

        [DBus (name = "EventGroup")]
        public void event_group (
            [DBus (signature = "a(isvu)")] GLib.Variant events,
            [DBus (signature = "ai")] out GLib.Variant errors)
            throws GLib.Error {
            for (size_t i = 0; i < events.n_children (); i++) {
                var ev = events.get_child_value (i);
                int id = ev.get_child_value (0).get_int32 ();
                string event_id = ev.get_child_value (1).get_string ();
                tray.dispatch_menu_event (id, event_id);
            }
            errors = empty_int_array ();
        }

        [DBus (name = "AboutToShow")]
        public bool about_to_show (int id) throws GLib.Error {
            return false;
        }

        [DBus (name = "AboutToShowGroup")]
        public void about_to_show_group (
            [DBus (signature = "ai")] GLib.Variant ids,
            [DBus (signature = "ai")] out GLib.Variant updates_needed,
            [DBus (signature = "ai")] out GLib.Variant id_errors)
            throws GLib.Error {
            updates_needed = empty_int_array ();
            id_errors = empty_int_array ();
        }

        [DBus (name = "ItemsPropertiesUpdated")]
        public signal void items_properties_updated (
            [DBus (signature = "a(ia{sv})")] GLib.Variant updated_props,
            [DBus (signature = "a(ias)")] GLib.Variant removed_props);

        [DBus (name = "LayoutUpdated")]
        public signal void layout_updated (uint revision, int parent);
    }
}