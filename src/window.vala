/* window.vala
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

[GtkTemplate (ui = "/im/apodaca/owlet/window.ui")]
public class Owlet.Window : Adw.ApplicationWindow {
    [GtkChild] private unowned Gtk.Stack stack;
    [GtkChild] private unowned Gtk.TextView transcript_view;
    [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild] private unowned Gtk.ToggleButton dictate_btn;
    [GtkChild] private unowned Adw.Banner recording_banner;

    [GtkChild] private unowned Gtk.Stack reader_content_stack;
    [GtkChild] private unowned Gtk.TextView reader_text_view;
    [GtkChild] private unowned Gtk.Label reader_doc_title_label;
    [GtkChild] private unowned Gtk.Button reader_play_btn;
    [GtkChild] private unowned Gtk.Button reader_pause_btn;
    [GtkChild] private unowned Gtk.Button reader_stop_btn;
    [GtkChild] private unowned Gtk.DropDown reader_speed_dropdown;
    [GtkChild] private unowned Gtk.Label reader_position_label;
    [GtkChild] private unowned Gtk.Label reader_status_label;
    [GtkChild] private unowned Adw.StatusPage reader_downloading_page;
    [GtkChild] private unowned Adw.StatusPage reader_no_voice_page;
    [GtkChild] private unowned Gtk.Button reader_cancel_dl_btn;
    [GtkChild] private unowned Gtk.Button reader_retry_dl_btn;

    public Owlet.Document? reader_doc { get; private set; default = null; }
    public string? reader_doc_path { get; private set; default = null; }

    private GLib.SimpleAction record_action;
    private GLib.SimpleAction stop_action;
    private GLib.SimpleAction dictate_action;
    private GLib.SimpleAction reader_start_from_here_action;

    private Owlet.Recorder recorder;
    private Owlet.TranscriptionSource source;
    private Owlet.Keystroke keystroke;
    private Owlet.SoundFeedback sound_feedback;
    private Owlet.SilenceDetector silence_detector;
    private Owlet.DictationHud hud;
    private Owlet.SpeechPlayer player;

    private bool reader_download_initiated = false;
    private Cancellable? reader_cancellable = null;
    private ulong _reader_progress_id = 0;
    private ulong _reader_completed_id = 0;
    private ulong _reader_failed_id = 0;
    private uint test_close_timeout_id = 0;

    // How dictation was launched. FOREGROUND (in-window Dictate) keeps
    // the minimize + 250 ms delay and skips the HUD. BACKGROUND
    // (global shortcut / tray) shows the OSD and starts immediately.
    private enum DictationLaunchMode {
        FOREGROUND,
        BACKGROUND
    }

    // Follow-along highlight (KTD4/KTD5). One reused tag paints the word
    // being spoken and one mark anchors the follow-scroll; the flag is
    // what makes the map / play-enter paths stop chasing a word that is
    // gone, since a mark alone always resolves to some position.
    private Gtk.TextTag reader_word_tag;
    private Gtk.TextMark reader_word_mark;
    private bool reader_has_word = false;
    // Last secondary-click character offset in the reader buffer. -1
    // means the context menu was not opened from a pointer click
    // (Shift+F10), so Start from here falls back to selection / word /
    // insert.
    private int reader_context_offset = -1;

    // Mark at the start of the current recording's text region.
    // left_gravity=true keeps the mark before text inserted at it,
    // so it stays at the boundary between committed (previous
    // utterances) and the current recording's tentative text.
    private Gtk.TextMark utterance_start;

    // Batch-mode chunk accumulator (used only when streaming is off
    // or the model doesn't support streaming).
    private float[] batch_buf = new float[0];

    // UI-level recording flag: true from recording_started through
    // stream_finalize / batch completion (including the finalize
    // step). Action sensitivity follows this, so the user can't
    // start a new recording while the previous one is finalizing.
    private bool recording = false;

    // Dictation mode: when true, the streamed transcript is also
    // injected (via `keystroke`) into whatever window had focus before
    // Owlet minimized. `last_typed` tracks the cumulative text already
    // sent so only the delta per partial is typed.
    private bool dictating = false;
    private string last_typed = "";

    // Source ID for the 250 ms minimize→record delay. Stored so it can
    // be cancelled if the window is destroyed during the delay (avoids
    // a use-after-free when the timeout fires after `this` is freed).
    private uint start_timeout_id = 0;

    // True only after source.prepare() completes successfully. Decouples
    // action gating (record/stop/dictate) from the visible stack page so
    // recording works while other pages (like the reader page) are visible.
    private bool source_ready = false;

    // map fires on every show, including close-to-tray restore. Prepare
    // once so a later map cannot reload the model or leave the reader.
    private bool source_prepare_started = false;

    // Cached settings (constructed once; read on every partial/final).
    private GLib.Settings settings;

    public Window (Gtk.Application app) {
        Object (application: app);

        // Customizable accelerators (Record / Stop / Insert / Dictate)
        // are read from GSettings and applied by Owlet.Application at
        // startup and on every shortcut-* change (see
        // application.vala::apply_shortcuts). Only the non-customizable
        // copy / clear bindings remain hardcoded here.
        var owlet_app = (Owlet.Application) app;
        owlet_app.set_accels_for_action ("win.copy",     {"<Control><Shift>C"});
        owlet_app.set_accels_for_action ("win.clear",    {"<Control>Delete"});
        owlet_app.set_accels_for_action ("win.open-doc", {"<Control>o"});
    }

    construct {
        recorder = new Owlet.Recorder ();
        keystroke = new Owlet.Keystroke ();
        settings = new GLib.Settings ("im.apodaca.owlet");
        sound_feedback = new Owlet.SoundFeedback (settings);
        silence_detector = new Owlet.SilenceDetector ();
        hud = new Owlet.DictationHud ();

        // Pick the keystroke backend from settings. auto|libei|ydotool|
        // xdotool map to the Keystroke.Backend enum; an unknown value
        // falls through to AUTO.
        string backend_name = settings.get_string ("keystroke-backend");
        Owlet.Keystroke.Backend preferred;
        switch (backend_name) {
        case "libei":   preferred = Owlet.Keystroke.Backend.LIBEI;   break;
        case "ydotool": preferred = Owlet.Keystroke.Backend.YDOTOOL; break;
        case "xdotool": preferred = Owlet.Keystroke.Backend.XDOTOOL; break;
        default:        preferred = Owlet.Keystroke.Backend.AUTO;     break;
        }
        keystroke.init (preferred);

        // Actions. Record/stop/dictate are SimpleAction so we can
        // toggle their enabled state; copy/clear/insert are always-on.
        // `dictate` is stateless and toggled in its activate handler:
        // a stateful boolean action can't be cleanly activated by a
        // keyboard accelerator (it needs a "b" parameter that the
        // accel machinery doesn't supply), so we manage the toggle
        // button's active state explicitly.
        record_action = new GLib.SimpleAction ("record", null);
        record_action.activate.connect (on_record);
        add_action (record_action);

        stop_action = new GLib.SimpleAction ("stop", null);
        stop_action.activate.connect (on_stop);
        add_action (stop_action);

        dictate_action = new GLib.SimpleAction ("dictate", null);
        dictate_action.activate.connect (on_dictate_toggle);
        add_action (dictate_action);

        var copy_action = new GLib.SimpleAction ("copy", null);
        copy_action.activate.connect (on_copy);
        add_action (copy_action);

        var clear_action = new GLib.SimpleAction ("clear", null);
        clear_action.activate.connect (on_clear);
        add_action (clear_action);

        // win.insert: copy the transcript to the clipboard AND type it
        // into the previously focused window. Bound to the customizable
        // shortcut-insert GSettings key (default <Control>I) via
        // Owlet.Application.apply_shortcuts ().
        var insert_action = new GLib.SimpleAction ("insert", null);
        insert_action.activate.connect (on_insert);
        add_action (insert_action);

        var open_doc_action = new GLib.SimpleAction ("open-doc", null);
        open_doc_action.activate.connect (on_open_doc_action);
        add_action (open_doc_action);

        var close_doc_action = new GLib.SimpleAction ("close-doc", null);
        close_doc_action.activate.connect (on_close_doc_action);
        add_action (close_doc_action);

        player = new Owlet.SpeechPlayer ();
        player.playback_started.connect (on_player_started);
        player.playback_stopped.connect (on_player_stopped);
        player.position_changed.connect (on_player_position_changed);
        player.error_occurred.connect (on_player_error);
        player.word_changed.connect (on_player_word_changed);
        player.notify["state"].connect (() => {
            update_reader_transport_ui ();
            update_action_state ();
            // Resume does not re-emit word_changed, so entering PLAYING is
            // where the viewport returns to the frozen word (KTD5, AE4).
            if (player.is_playing)
                scroll_to_current_word ();
        });

        var reader_buf = reader_text_view.buffer;
        reader_word_tag = new Gtk.TextTag ("owlet-current-word");
        reader_buf.tag_table.add (reader_word_tag);
        reader_word_mark = new Gtk.TextMark ("owlet-current-word", true);
        Gtk.TextIter reader_origin;
        reader_buf.get_start_iter (out reader_origin);
        reader_buf.add_mark (reader_word_mark, reader_origin);

        apply_word_tag_colors ();
        var style_manager = Adw.StyleManager.get_default ();
        style_manager.notify["dark"].connect (apply_word_tag_colors);
        style_manager.notify["high-contrast"].connect (apply_word_tag_colors);
        style_manager.notify["accent-color"].connect (apply_word_tag_colors);

        reader_text_view.map.connect (on_reader_text_view_mapped);

        var reader_click = new Gtk.GestureClick ();
        reader_click.set_button (Gdk.BUTTON_SECONDARY);
        reader_click.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        reader_click.pressed.connect (on_reader_context_pressed);
        reader_text_view.add_controller (reader_click);

        reader_speed_dropdown.set_selected (
            SpeechPlayer.snap_speed_index (
                (float) settings.get_double ("reader-playback-speed")));
        reader_speed_dropdown.notify["selected"].connect (() => {
            uint s = reader_speed_dropdown.get_selected ();
            if (s == Gtk.INVALID_LIST_POSITION
                || s >= (uint) SpeechPlayer.SPEED_PRESETS.length)
                return;
            float speed = SpeechPlayer.SPEED_PRESETS[s];
            settings.set_double ("reader-playback-speed", (double) speed);
            player.set_speed (speed);
        });

        player.set_sid (Owlet.VoiceModels.sid_for_name (
            settings.get_string ("reader-voice")));
        settings.changed["reader-voice"].connect (() => {
            player.set_sid (Owlet.VoiceModels.sid_for_name (
                settings.get_string ("reader-voice")));
        });

        var reader_play_action = new GLib.SimpleAction ("reader-play", null);
        reader_play_action.activate.connect (on_reader_play);
        add_action (reader_play_action);

        var reader_pause_action = new GLib.SimpleAction ("reader-pause", null);
        reader_pause_action.activate.connect (on_reader_pause);
        add_action (reader_pause_action);

        var reader_stop_action = new GLib.SimpleAction ("reader-stop", null);
        reader_stop_action.activate.connect (on_reader_stop);
        add_action (reader_stop_action);

        reader_start_from_here_action = new GLib.SimpleAction ("reader-start-from-here", null);
        reader_start_from_here_action.activate.connect (on_reader_start_from_here);
        add_action (reader_start_from_here_action);
        reader_start_from_here_action.set_enabled (false);

        var reader_dl_action = new GLib.SimpleAction ("reader-download-voice", null);
        reader_dl_action.activate.connect (on_reader_download_voice);
        add_action (reader_dl_action);

        var reader_cancel_dl_action = new GLib.SimpleAction ("reader-cancel-download", null);
        reader_cancel_dl_action.activate.connect (on_reader_cancel_download);
        add_action (reader_cancel_dl_action);

        // Test-only startup open seam (U5).
        string? test_open = GLib.Environment.get_variable ("OWLET_TEST_OPEN");
        if (test_open != null && test_open != "") {
            Idle.add (() => {
                open_document_file (test_open);
                return false;
            });
        }

        // Test-only in-process Close seam. The UI harness touches this
        // path after NameHasOwner is true; process kill is not Close.
        string? test_close = GLib.Environment.get_variable ("OWLET_TEST_CLOSE");
        if (test_close != null && test_close != "") {
            test_close_timeout_id = Timeout.add (100, () => {
                if (!GLib.FileUtils.test (test_close, GLib.FileTest.EXISTS))
                    return true;
                test_close_timeout_id = 0;
                on_close_doc_action ();
                return false;
            });
        }

        // Recorder signals.
        recorder.chunk_ready.connect (on_chunk);
        recorder.recording_started.connect (on_recording_started);
        recorder.recording_stopped.connect (on_recording_stopped);
        recorder.error_occurred.connect (on_recorder_error);

        // Source signals (partial_text / final_text / error_occurred)
        // are wired in prepare_source_async () once the source is built.

        // Auto-prepare the source (local model or remote API) when the
        // window is mapped (the `realize` signal is shadowed by
        // Gtk.Native's realize() method in the GTK4 VAPI, so we use
        // `map` which fires right after realize when the window
        // becomes visible). Guarded so close-to-tray restore does not
        // re-enter prepare and reset the stack off the reader.
        this.map.connect (on_map_prepare_source);

        // Place the utterance-start mark at the buffer origin; it
        // moves to end-of-buffer on each recording_started.
        var buf = transcript_view.buffer;
        utterance_start = new Gtk.TextMark (null, true);
        Gtk.TextIter start_iter;
        buf.get_start_iter (out start_iter);
        buf.add_mark (utterance_start, start_iter);

        update_action_state ();
    }

    public override bool close_request () {
        var app = this.application as Owlet.Application;
        bool quitting = app != null && app.quitting;
        // Pref off, or an explicit Quit, destroys the window (last
        // window quits the app). Pref on + the titlebar close button
        // hides instead, so global shortcuts / dictation keep a live
        // Window and the StatusNotifierItem tray can restore it.
        if (!quitting && settings.get_boolean ("close-to-tray")) {
            this.hide ();
            if (app != null)
                app.request_hide_to_tray ();
            return true;
        }
        prepare_for_quit ();
        return base.close_request ();
    }

    // Stop TTS before destroy so GStreamer/sherpa threads are not
    // still blocked when Gtk.Application shuts down.
    public void prepare_for_quit () {
        player.shutdown ();
    }

    /* ----------------------------------------------------------------- */
    /* Source dispatch + prepare                                          */
    /* ----------------------------------------------------------------- */

    private void on_map_prepare_source () {
        if (source_prepare_started)
            return;
        source_prepare_started = true;
        prepare_source_async.begin ();
    }

    // Build the configured TranscriptionSource (local or remote per
    // the transcription-source GSettings key), wire its signals, and
    // run prepare() — LocalSource reads the user-configured model-path
    // and loads the model, RemoteOpenAISource validates endpoint +
    // model. Stack pages: "loading" while prepare runs, "active" on
    // success, "empty" on failure (with a toast so a missing key /
    // bad endpoint / no model configured is visible).
    private async void prepare_source_async () {
        string src = settings.get_string ("transcription-source");
        if (src == "api") {
            var remote = new Owlet.RemoteOpenAISource ();
            remote.endpoint         = settings.get_string ("api-endpoint");
            remote.model            = settings.get_string ("api-model");
            remote.response_format  = settings.get_string ("api-response-format");
            remote.temperature      = settings.get_double ("api-temperature");
            remote.translate        = settings.get_boolean ("api-translate");
            try {
                var secret = new Owlet.SecretStore ();
                string? key = yield secret.get_api_key ();
                remote.api_key = key ?? "";
            } catch (GLib.Error e) {
                warning ("Cannot read API key from keyring: %s", e.message);
                remote.api_key = "";
            }
            source = remote;
        } else {
            source = new Owlet.LocalSource ();
        }

        // Source signals fire on the main thread for both backends
        // (LocalSource resumes its worker threads via Idle.add;
        // RemoteOpenAISource runs entirely on the main thread).
        source.partial_text.connect (on_partial_text);
        source.final_text.connect (on_final_text);
        source.error_occurred.connect (on_source_error);

        source_ready = false;
        // A document can be opened (or already showing) while prepare
        // is in flight. Do not steal the reader page on completion.
        if (stack.visible_child_name != "reader")
            stack.visible_child_name = "loading";
        try {
            yield source.prepare ();
            source_ready = true;
            if (stack.visible_child_name != "reader")
                stack.visible_child_name = "active";
        } catch (GLib.Error e) {
            source_ready = false;
            warning ("Source prepare failed: %s", e.message);
            if (stack.visible_child_name != "reader")
                stack.visible_child_name = "empty";
            toast_overlay.add_toast (new Adw.Toast (
                _("Prepare failed: %s").printf (e.message)));
        }
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Action state                                                       */
    /* ----------------------------------------------------------------- */

    private void update_action_state () {
        record_action.set_enabled (source_ready && !recording);
        stop_action.set_enabled (source_ready && recording);
        // Dictate stays clickable whenever a source is prepared and a
        // keystroke backend is available; toggling it off must remain
        // possible mid-dictation, so it isn't gated on `!recording`.
        // TTS playback captures on the default source, so Dictate is
        // disabled while speech is playing (button, accel, and the
        // global/tray wrappers below all honor the same guard).
        dictate_action.set_enabled (
            source_ready
            && keystroke.backend != Owlet.Keystroke.Backend.NONE
            && !player.is_playing);
    }

    /* ----------------------------------------------------------------- */
    /* Global-shortcut entry points                                       */
    /* ----------------------------------------------------------------- */

    // Public wrappers used by the global-shortcut handlers in
    // Owlet.Application (portal Activated signal + Unix USR1/USR2/RTMIN+1
    // fallback). They delegate to the private activate handlers, which
    // already guard against re-entrant / no-op calls, so the action-
    // enabled gating (which depends on the in-window stack page being
    // "active") is deliberately bypassed — a global toggle must work
    // even when the window is minimized or on a non-"active" page.
    // Playback is the exception: Dictate is a no-op while TTS is playing.
    public bool is_recording { get { return recording; } }

    public void record () { on_record (); }
    public void stop ()   { on_stop (); }

    // In-window Dictate entry point: minimize + 250 ms delay, no HUD.
    public void toggle_dictation () { on_dictate_toggle (); }

    // Global-shortcut / tray entry point: no minimize; show the
    // dictation HUD OSD and start the recorder immediately. Toggle
    // off shares the same finalize path as in-window Dictate.
    public void toggle_dictation_background () {
        if (player.is_playing)
            return;
        if (dictating) {
            dictate_btn.active = false;
            stop_dictation ();
        } else {
            if (keystroke.backend == Owlet.Keystroke.Backend.NONE) {
                toast_overlay.add_toast (new Adw.Toast (
                    _("No keystroke backend available")));
                return;
            }
            dictate_btn.active = true;
            start_dictation (DictationLaunchMode.BACKGROUND);
        }
    }

    // MPRIS / hardware media-key entry. Not win.reader-play: that
    // action restarts the current sentence unless already paused.
    public void reader_play_pause () {
        if (!reader_on_content_page ())
            return;
        if (player.is_playing)
            reader_pause ();
        else
            reader_play ();
    }

    public void reader_play () {
        if (!reader_on_content_page ())
            return;
        if (player.is_playing)
            return;
        on_reader_play ();
    }

    public void reader_pause () {
        if (!reader_on_content_page ())
            return;
        player.pause ();
    }

    private bool reader_on_content_page () {
        return reader_doc != null
            && reader_content_stack.visible_child_name == "content";
    }

    private void sync_mpris () {
        var app = this.application as Owlet.Application;
        if (app == null)
            return;
        string title = "";
        if (reader_doc_path != null)
            title = GLib.Path.get_basename (reader_doc_path);
        app.sync_reader_mpris (reader_on_content_page (), title, player.state);
    }

    // Refuse the global "insert" shortcut while dictation is streaming
    // typed partials: on_insert() types the buffer via the keystroke
    // backend, which would interleave with the in-flight dictation
    // typing and garble the target window. The in-window win.insert
    // action (which calls on_insert directly) keeps its pre-existing
    // behavior; only the new global-shortcut entry point is guarded.
    public void insert () {
        if (dictating) {
            toast_overlay.add_toast (new Adw.Toast (
                _("Stop dictation before inserting text")));
            return;
        }
        on_insert ();
    }

    /* ----------------------------------------------------------------- */
    /* Record / stop                                                      */
    /* ----------------------------------------------------------------- */

    private void on_record () {
        if (recording)
            return;
        if (source == null) {
            // We only land here if the stack is "active", which
            // implies the source prepared. Defensive guard anyway.
            warning ("Record pressed with no source prepared");
            return;
        }
        try {
            recorder.start ();
        } catch (GLib.Error e) {
            warning ("Recorder start failed: %s", e.message);
        }
        // recording_started signal drives the state transition.
    }

    private void on_recording_started () {
        set_recording_state (true);
        sound_feedback.play_start ();

        // Move the utterance-start mark to the end of the buffer so
        // the new recording's text is appended after any prior
        // transcript (or user edits).
        var buf = transcript_view.buffer;
        Gtk.TextIter end_iter;
        buf.get_end_iter (out end_iter);
        buf.move_mark (utterance_start, end_iter);

        if (use_streaming ()) {
            source.stream_begin.begin ();
        } else {
            batch_buf = new float[0];
        }

        update_action_state ();
    }

    private void on_chunk (float[] samples) {
        if (!recording)
            return;
        if (use_streaming ()) {
            source.stream_feed.begin (samples);
        } else {
            // Append to the batch accumulator.
            int old_len = batch_buf.length;
            batch_buf.resize (old_len + samples.length);
            for (int i = 0; i < samples.length; i++) {
                batch_buf[old_len + i] = samples[i];
            }
        }

        // Dictation silence auto-stop (opt-in). Observe on the GST
        // thread; schedule stop_dictation on the main loop.
        if (!dictating || !settings.get_boolean ("dictation-auto-stop"))
            return;
        int pause = settings.get_int ("dictation-auto-stop-pause-ms");
        if (pause < 500)
            pause = 500;
        else if (pause > 5000)
            pause = 5000;
        silence_detector.pause_ms = pause;
        silence_detector.speech_rms_threshold =
            (float) settings.get_double ("dictation-auto-stop-threshold");
        if (silence_detector.observe (samples)) {
            GLib.Idle.add (() => {
                stop_dictation ();
                return false;
            });
        }
    }

    private void on_stop () {
        if (!recording)
            return;
        sound_feedback.play_stop ();
        recorder.stop ();
        // recording_stopped drives the finalize / batch path.
    }

    private void on_recording_stopped () {
        if (use_streaming ()) {
            source.stream_finalize.begin (null, (obj, res) => {
                source.stream_finalize.end (res);
                set_recording_state (false);
                if (dictating)
                    clear_dictation_state ();
                update_action_state ();
            });
        } else {
            transcribe_batch_async.begin ();
        }
    }

    private async void transcribe_batch_async () {
        try {
            string text = yield source.transcribe_batch (batch_buf);
            var buf = transcript_view.buffer;
            Gtk.TextIter mark_iter;
            buf.get_iter_at_mark (out mark_iter, utterance_start);
            string full = text + "\n";
            buf.insert (ref mark_iter, full, full.length);
            Gtk.TextIter end_iter;
            buf.get_end_iter (out end_iter);
            buf.move_mark (utterance_start, end_iter);

            // In dictation + batch mode there are no partials, so the
            // whole final transcript is typed in one shot (with the
            // optional trailing newline) and last_typed stays "".
            if (dictating && auto_type_enabled ()) {
                type_dictation (text, true);
            }
            if (dictating)
                hud.set_text (text);
        } catch (GLib.Error e) {
            warning ("Batch transcribe failed: %s", e.message);
        }
        set_recording_state (false);
        if (dictating)
            clear_dictation_state ();
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Dictation mode                                                   */
    /* ----------------------------------------------------------------- */

    private void on_dictate_toggle () {
        if (player.is_playing)
            return;
        if (dictating) {
            dictate_btn.active = false;
            stop_dictation ();
        } else {
            if (keystroke.backend == Owlet.Keystroke.Backend.NONE) {
                toast_overlay.add_toast (new Adw.Toast (
                    _("No keystroke backend available")));
                return;
            }
            dictate_btn.active = true;
            start_dictation (DictationLaunchMode.FOREGROUND);
        }
    }

    private void start_dictation (DictationLaunchMode mode) {
        if (recording) {
            // Record was already started via the Record button; just
            // mark dictation so the partials also get typed out.
            // In-window path: no HUD. Background path: show OSD.
            dictating = true;
            last_typed = "";
            reset_silence_detector ();
            if (mode == DictationLaunchMode.BACKGROUND)
                maybe_show_dictation_hud ();
            return;
        }
        if (source == null) {
            warning ("Dictate pressed with no source prepared");
            return;
        }
        dictating = true;
        last_typed = "";
        reset_silence_detector ();

        if (mode == DictationLaunchMode.BACKGROUND) {
            // Global/tray: Owlet is already backgrounded in the common
            // case — skip minimize, show the OSD, start immediately.
            maybe_show_dictation_hud ();
            try {
                recorder.start ();
            } catch (GLib.Error e) {
                warning ("Recorder start failed: %s", e.message);
                clear_dictation_state ();
                this.present ();
                toast_overlay.add_toast (new Adw.Toast (
                    _("Recorder start failed: %s").printf (e.message)));
                update_action_state ();
            }
            return;
        }

        // Foreground (in-window Dictate): minimize so the previously
        // focused window receives the injected keystrokes. A short
        // delay lets the WM hand focus back before capture starts.
        this.minimize ();
        start_timeout_id = GLib.Timeout.add (250, () => {
            start_timeout_id = 0;
            if (!dictating)
                return false;
            try {
                recorder.start ();
            } catch (GLib.Error e) {
                warning ("Recorder start failed: %s", e.message);
                clear_dictation_state ();
                this.present ();
                toast_overlay.add_toast (new Adw.Toast (
                    _("Recorder start failed: %s").printf (e.message)));
                update_action_state ();
            }
            return false;
        });
    }

    private void stop_dictation () {
        if (!dictating)
            return;
        if (recording) {
            sound_feedback.play_stop ();
            recorder.stop ();
            // recording_stopped drives the finalize path; dictating is
            // cleared in on_recording_stopped / transcribe_batch_async
            // once the final transcript has been typed out. HUD stays
            // up until clear_dictation_state() so finals can render.
        } else {
            // Recording hasn't started yet (e.g. the user toggled
            // Dictate off during the 250 ms minimize delay). Clear
            // dictation now; the pending Timeout will see !dictating
            // and skip recorder.start().
            if (start_timeout_id != 0) {
                GLib.Source.remove (start_timeout_id);
                start_timeout_id = 0;
            }
            clear_dictation_state ();
        }
    }

    private void clear_dictation_state () {
        dictating = false;
        dictate_btn.active = false;
        last_typed = "";
        silence_detector.reset ();
        hud.hide ();
    }

    private void reset_silence_detector () {
        int pause = settings.get_int ("dictation-auto-stop-pause-ms");
        if (pause < 500)
            pause = 500;
        else if (pause > 5000)
            pause = 5000;
        silence_detector.pause_ms = pause;
        silence_detector.speech_rms_threshold =
            (float) settings.get_double ("dictation-auto-stop-threshold");
        silence_detector.reset ();
    }

    // Background dictation OSD, gated by the dictation-hud GSettings
    // key (default true). When disabled, global/tray dictation still
    // runs; set_text is already a no-op unless the HUD was shown.
    private void maybe_show_dictation_hud () {
        if (owlet_holds_focus ())
            return;
        if (settings.get_boolean ("dictation-hud"))
            hud.show ();
    }

    // win.insert: copy the transcript to the clipboard AND type it
    // into the previously focused window. Bound to the customizable
    // shortcut-insert GSettings key (default <Control>I).
    private void on_insert () {
        if (keystroke.backend == Owlet.Keystroke.Backend.NONE) {
            toast_overlay.add_toast (new Adw.Toast (
                _("No keystroke backend available")));
            return;
        }
        string text = transcript_view.buffer.text;
        if (text.length == 0) {
            toast_overlay.add_toast (new Adw.Toast (
                _("Buffer is empty — type something to insert first")));
            return;
        }
        var clipboard = Gdk.Display.get_default ().get_clipboard ();
        clipboard.set_text (text);
        this.minimize ();
        GLib.Timeout.add (250, () => {
            keystroke.type_text.begin (text);
            return false;
        });
    }

    /* ----------------------------------------------------------------- */
    /* Source text → buffer                                               */
    /* ----------------------------------------------------------------- */

    private void on_partial_text (string text) {
        var buf = transcript_view.buffer;
        Gtk.TextIter start, end;
        buf.get_iter_at_mark (out start, utterance_start);
        buf.get_end_iter (out end);
        buf.@delete (ref start, ref end);
        Gtk.TextIter insert_iter;
        buf.get_iter_at_mark (out insert_iter, utterance_start);
        buf.insert (ref insert_iter, text, text.length);

        if (dictating && auto_type_enabled ())
            type_dictation (text, false);
        if (dictating)
            hud.set_text (text);
    }

    private void on_final_text (string text) {
        var buf = transcript_view.buffer;
        Gtk.TextIter start, end;
        buf.get_iter_at_mark (out start, utterance_start);
        buf.get_end_iter (out end);
        buf.@delete (ref start, ref end);
        Gtk.TextIter insert_iter;
        buf.get_iter_at_mark (out insert_iter, utterance_start);
        string full = text + "\n";
        buf.insert (ref insert_iter, full, full.length);
        Gtk.TextIter new_end;
        buf.get_end_iter (out new_end);
        buf.move_mark (utterance_start, new_end);

        if (dictating && auto_type_enabled ())
            type_dictation (text, true);
        if (dictating)
            hud.set_text (text);
    }

    /* ----------------------------------------------------------------- */
    /* Copy / clear                                                       */
    /* ----------------------------------------------------------------- */

    private void on_copy () {
        var clipboard = Gdk.Display.get_default ().get_clipboard ();
        clipboard.set_text (transcript_view.buffer.text);
    }

    private void on_clear () {
        var buf = transcript_view.buffer;
        buf.set_text ("", -1);
        Gtk.TextIter start_iter;
        buf.get_start_iter (out start_iter);
        buf.move_mark (utterance_start, start_iter);
    }

    /* ----------------------------------------------------------------- */
    /* Error handling                                                     */
    /* ----------------------------------------------------------------- */

    private void on_recorder_error (string message) {
        warning ("Recorder error: %s", message);
        set_recording_state (false);
        if (dictating) {
            clear_dictation_state ();
            this.present ();
            toast_overlay.add_toast (new Adw.Toast (
                _("Recorder error: %s").printf (message)));
        }
        update_action_state ();
    }

    private void on_source_error (string message) {
        warning ("Source error: %s", message);
        toast_overlay.add_toast (new Adw.Toast (
            _("Source error: %s").printf (message)));
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Helpers                                                            */
    /* ----------------------------------------------------------------- */

    // Flip the UI recording flag and push the same state to the tray
    // (Application caches it even when the tray is not visible) and the
    // mic-live recording banner (visible on every window page).
    private void set_recording_state (bool active) {
        recording = active;
        recording_banner.revealed = active;
        var app = this.application as Owlet.Application;
        if (app != null)
            app.set_tray_recording (active);
    }

    private bool use_streaming () {
        return settings.get_boolean ("use-streaming")
               && source.can_stream;
    }

    private bool auto_type_enabled () {
        return settings.get_boolean ("dictation-auto-type");
    }

    private bool owlet_holds_focus () {
        var app = this.application;
        if (app == null)
            return this.is_active;
        foreach (weak Gtk.Window w in app.get_windows ()) {
            if (w.is_active)
                return true;
        }
        return false;
    }

    // Send the new suffix of `text` (relative to last_typed) through
    // the keystroke backend. For final text, optionally append a
    // trailing newline per the user setting. last_typed is reset to
    // "" after a final so the next utterance's deltas start fresh.
    //
    // The streaming model emits monotonic prefixes (committed grows,
    // tentative extends the tail), so the common path is a clean
    // suffix. When the model revises (prefix mismatch), we skip the
    // injection for that update to avoid corrupting the target
    // window — the buffer still shows the corrected text.
    private void type_dictation (string text, bool is_final) {
        string delta = "";
        if (last_typed.length > 0 && text.has_prefix (last_typed)) {
            delta = text.substring (last_typed.length);
        } else if (last_typed.length == 0) {
            delta = text;
        }
        last_typed = text;

        // Transcript already received this text. Injecting into the
        // focused Owlet window types it a second time into the view.
        if (owlet_holds_focus ()) {
            if (is_final)
                last_typed = "";
            return;
        }

        if (delta.length > 0 && delta.validate ())
            keystroke.type_text.begin (delta);

        if (is_final) {
            if (settings.get_boolean ("dictation-trailing-newline"))
                keystroke.type_text.begin ("\n");
            last_typed = "";
        }
    }

    /* ----------------------------------------------------------------- */
    /* Document Reader & Playback (U5, U10)                              */
    /* ----------------------------------------------------------------- */

    private void on_open_doc_action () {
        open_doc_dialog_async.begin ();
    }

    private async void open_doc_dialog_async () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Open Text or Markdown Document");

        var filter_list = new GLib.ListStore (typeof (Gtk.FileFilter));

        var text_filter = new Gtk.FileFilter ();
        text_filter.name = _("Text & Markdown files");
        text_filter.add_pattern ("*.txt");
        text_filter.add_pattern ("*.md");
        text_filter.add_pattern ("*.markdown");
        text_filter.add_mime_type ("text/plain");
        text_filter.add_mime_type ("text/markdown");
        filter_list.append (text_filter);

        var all_filter = new Gtk.FileFilter ();
        all_filter.name = _("All files");
        all_filter.add_pattern ("*");
        filter_list.append (all_filter);

        dialog.filters = filter_list;
        dialog.default_filter = text_filter;

        try {
            var file = yield dialog.open (this, null);
            if (file != null) {
                open_document_file (file.get_path ());
            }
        } catch (GLib.Error e) {
            // Cancelled or dismissed
        }
    }

    public void open_document_file (string file_path) {
        player.stop ();
        // Offsets are measured against the outgoing document, so they must
        // not outlive it even when nothing was playing to emit a stop (R4).
        clear_word_highlight (true);
        if (reader_cancellable != null && reader_download_initiated) {
            reader_cancellable.cancel ();
        }
        disconnect_reader_vm_signals ();

        var doc = Owlet.Document.load (file_path);
        switch (doc.status) {
        case Owlet.DocumentStatus.OK:
            reader_doc = doc;
            reader_doc_path = file_path;
            reader_doc_title_label.label = GLib.Path.get_basename (file_path);
            reader_text_view.buffer.text = string.joinv (Owlet.Document.DISPLAY_SEPARATOR, doc.sentences);
            stack.visible_child_name = "reader";

            var app = this.application as Owlet.Application;
            var voice_status = (app != null) ? app.voice_models.get_status () : Owlet.VoiceStatus.NOT_INSTALLED;

            if (voice_status == Owlet.VoiceStatus.INSTALLED) {
                reader_content_stack.visible_child_name = "content";
                update_reader_transport_ui ();
                start_reader_playback ();
            } else {
                start_reader_voice_download ();
            }
            break;

        case Owlet.DocumentStatus.EMPTY:
            reader_doc = doc;
            reader_doc_path = file_path;
            reader_doc_title_label.label = GLib.Path.get_basename (file_path);
            reader_text_view.buffer.text = "";
            reader_position_label.label = "";
            reader_content_stack.visible_child_name = "empty";
            stack.visible_child_name = "reader";
            update_reader_transport_ui ();
            break;

        case Owlet.DocumentStatus.NOT_TEXT:
        case Owlet.DocumentStatus.UNSUPPORTED_ENCODING:
        case Owlet.DocumentStatus.IO_ERROR:
        default:
            toast_overlay.add_toast (new Adw.Toast (doc.error_message));
            break;
        }
    }

    private void on_close_doc_action () {
        player.stop ();
        clear_word_highlight (true);
        if (reader_cancellable != null && reader_download_initiated) {
            reader_cancellable.cancel ();
        }
        disconnect_reader_vm_signals ();
        reader_doc = null;
        reader_doc_path = null;
        reader_text_view.buffer.text = "";
        reader_doc_title_label.label = "";
        reader_position_label.label = "";
        reader_status_label.visible = false;
        stack.visible_child_name = source_ready ? "active" : "empty";
        update_reader_transport_ui ();
    }

    private void on_reader_play () {
        if (reader_doc == null)
            return;
        if (player.is_paused) {
            player.resume ();
        } else {
            start_reader_playback ();
        }
    }

    private void on_reader_pause () {
        player.pause ();
        update_reader_transport_ui ();
    }

    private void on_reader_stop () {
        player.stop ();
    }

    private void on_reader_context_pressed (int n_press, double x, double y) {
        int buf_x, buf_y;
        reader_text_view.window_to_buffer_coords (
            Gtk.TextWindowType.WIDGET, (int) x, (int) y, out buf_x, out buf_y);
        Gtk.TextIter iter;
        reader_text_view.get_iter_at_location (out iter, buf_x, buf_y);
        reader_context_offset = iter.get_offset ();
    }

    private void on_reader_start_from_here () {
        if (reader_doc == null)
            return;

        int offset = reader_start_from_here_offset ();
        reader_context_offset = -1;

        int sentence = reader_doc.sentence_index_at_display_offset (offset);
        if (sentence < 0)
            return;

        int prefix = reader_doc.display_prefix_chars (sentence);
        int local = offset - prefix;
        if (local < 0)
            local = 0;

        string text = reader_doc.sentences[sentence];
        int word_start = Owlet.WordSpans.token_start_at (text, local);
        if (word_start >= (int) text.char_count ()
            && sentence + 1 < reader_doc.sentences.length) {
            sentence++;
            word_start = 0;
        }

        // Always play(), never resume(): a jump from pause or mid-play
        // must discard in-flight audio and begin at the chosen word.
        start_reader_playback (sentence, word_start);
    }

    // Prefer a nonempty selection (the word the user marked), then the
    // right-click location, then the highlighted word / insert cursor.
    private int reader_start_from_here_offset () {
        var buf = reader_text_view.buffer;
        Gtk.TextIter sel_start, sel_end;
        if (buf.get_selection_bounds (out sel_start, out sel_end)
            && sel_start.get_offset () != sel_end.get_offset ())
            return sel_start.get_offset ();
        if (reader_context_offset >= 0)
            return reader_context_offset;
        if (reader_has_word) {
            Gtk.TextIter iter;
            buf.get_iter_at_mark (out iter, reader_word_mark);
            return iter.get_offset ();
        }
        Gtk.TextIter insert;
        buf.get_iter_at_mark (out insert, buf.get_insert ());
        return insert.get_offset ();
    }

    private void on_reader_download_voice () {
        start_reader_voice_download ();
    }

    private void on_reader_cancel_download () {
        if (reader_cancellable != null && reader_download_initiated) {
            reader_cancellable.cancel ();
        }
        on_close_doc_action ();
    }

    private void start_reader_playback (int start_index = -1, int start_char = 0) {
        var app = this.application as Owlet.Application;
        if (app == null || reader_doc == null)
            return;

        reader_status_label.label = _("Preparing voice…");
        reader_status_label.visible = true;
        // play () halts the previous listen internally without emitting a
        // stop, so this is the only place a fresh Play can drop the old
        // offsets before the first word_changed arrives (R4, R10).
        clear_word_highlight (true);
        update_reader_transport_ui ();

        int idx = start_index >= 0 ? start_index : player.current_sentence_index;
        player.play (reader_doc, app.voice_models.get_voice_dir (),
                     idx,
                     Owlet.VoiceModels.sid_for_name (settings.get_string ("reader-voice")),
                     (float) settings.get_double ("reader-playback-speed"),
                     start_char);
    }

    private void start_reader_voice_download () {
        var app = this.application as Owlet.Application;
        if (app == null)
            return;

        disconnect_reader_vm_signals ();

        if (app.voice_models.download_in_progress) {
            // Download started elsewhere (e.g. Preferences); show downloading state without Cancel
            reader_download_initiated = false;
            reader_cancel_dl_btn.visible = false;
            reader_content_stack.visible_child_name = "downloading";
            reader_downloading_page.description = _("Downloading voice model…");

            _reader_progress_id = app.voice_models.progress.connect (on_reader_vm_progress);
            _reader_completed_id = app.voice_models.completed.connect (on_reader_vm_completed);
            _reader_failed_id = app.voice_models.failed.connect (on_reader_vm_failed);
            update_reader_transport_ui ();
            return;
        }

        reader_download_initiated = true;
        reader_cancel_dl_btn.visible = true;
        reader_content_stack.visible_child_name = "downloading";
        reader_downloading_page.description = _("Starting download…");

        reader_cancellable = new Cancellable ();

        _reader_progress_id = app.voice_models.progress.connect (on_reader_vm_progress);
        _reader_completed_id = app.voice_models.completed.connect (on_reader_vm_completed);
        _reader_failed_id = app.voice_models.failed.connect (on_reader_vm_failed);

        app.voice_models.download_voice_async.begin (null, null, Owlet.VoiceModels.DEFAULT_ARTIFACT_ID, reader_cancellable);
        update_reader_transport_ui ();
    }

    private void on_reader_vm_progress (int64 downloaded, int64 total) {
        string dl = GLib.format_size (downloaded);
        if (total > 0)
            reader_downloading_page.description = _("%s / %s").printf (dl, GLib.format_size (total));
        else
            reader_downloading_page.description = _("%s downloaded").printf (dl);
    }

    private void on_reader_vm_completed (string local_dir) {
        disconnect_reader_vm_signals ();
        player.invalidate_engine ();
        if (reader_doc != null && stack.visible_child_name == "reader") {
            reader_content_stack.visible_child_name = "content";
            update_reader_transport_ui ();
            start_reader_playback ();
        }
    }

    private void on_reader_vm_failed (string message) {
        disconnect_reader_vm_signals ();
        if (reader_doc != null && stack.visible_child_name == "reader") {
            reader_no_voice_page.description = _("Download failed: %s").printf (message);
            reader_content_stack.visible_child_name = "no_voice";
            update_reader_transport_ui ();
        }
    }

    private void disconnect_reader_vm_signals () {
        var app = this.application as Owlet.Application;
        if (app != null) {
            if (_reader_progress_id != 0) {
                app.voice_models.disconnect (_reader_progress_id);
                _reader_progress_id = 0;
            }
            if (_reader_completed_id != 0) {
                app.voice_models.disconnect (_reader_completed_id);
                _reader_completed_id = 0;
            }
            if (_reader_failed_id != 0) {
                app.voice_models.disconnect (_reader_failed_id);
                _reader_failed_id = 0;
            }
        }
        reader_cancellable = null;
    }

    private void on_player_started () {
        if (dictating)
            stop_dictation ();
        reader_status_label.visible = false;
        update_reader_transport_ui ();
        update_action_state ();
    }

    private void on_player_position_changed (int index, int total) {
        reader_status_label.visible = false;
        reader_position_label.label = _("%d / %d sentences").printf (index, total);
        update_reader_transport_ui ();
    }

    private void on_player_stopped (bool natural_end) {
        reader_status_label.visible = false;
        // Stop and natural end both reset position to the start (KTD-3).
        // The highlight goes with the audio, but the viewport stays put
        // (R4, R10). A resume failure leaves playback paused and emits no
        // stop, so the frozen word survives it (KTD5).
        clear_word_highlight (true);
        reader_position_label.label = "";
        update_reader_transport_ui ();
        update_action_state ();
    }

    private void on_player_word_changed (int sentence_index, int word_index,
                                         int start_offset, int end_offset) {
        if (word_index < 0) {
            // The speaking sentence has no highlightable word. Drop the
            // tag for its duration rather than leaving the previous
            // sentence's word lit (R1); the mark stays where it was.
            clear_word_highlight (false);
            return;
        }

        int prefix = reader_join_prefix (sentence_index);
        if (prefix < 0)
            return;
        if (!set_current_word (prefix + start_offset, prefix + end_offset))
            return;
        // While playing, every new word pulls the viewport back — scrolling
        // away by hand does not suspend follow-scroll (KTD5).
        if (player.is_playing)
            scroll_to_current_word ();
    }

    // Word events carry sentence-local offsets; the reader shows the
    // sentences joined by Document.DISPLAY_SEPARATOR (KTD3). Prefixes
    // are summed in characters to match the buffer's character offsets.
    // Negative when the event outlives the document it was measured against.
    private int reader_join_prefix (int sentence_index) {
        if (reader_doc == null)
            return -1;
        return reader_doc.display_prefix_chars (sentence_index);
    }

    // Repaints the tag and moves the mark onto [start, end). False when the
    // range does not fit the buffer, which leaves no cached word so the
    // scroll paths have nothing stale to chase.
    private bool set_current_word (int start, int end) {
        var buf = reader_text_view.buffer;
        Gtk.TextIter from, to;
        buf.get_bounds (out from, out to);
        buf.remove_tag (reader_word_tag, from, to);

        if (start < 0 || end <= start || end > buf.get_char_count ()) {
            reader_has_word = false;
            return false;
        }

        buf.get_iter_at_offset (out from, start);
        buf.get_iter_at_offset (out to, end);
        buf.apply_tag (reader_word_tag, from, to);
        buf.move_mark (reader_word_mark, from);
        reader_has_word = true;
        return true;
    }

    // `reset_mark` separates a transport halt, which sends the mark back to
    // the top, from a sentence with no highlightable word, which only drops
    // the tag. Either way no current word is left for the scroll paths.
    private void clear_word_highlight (bool reset_mark) {
        var buf = reader_text_view.buffer;
        Gtk.TextIter from, to;
        buf.get_bounds (out from, out to);
        buf.remove_tag (reader_word_tag, from, to);

        reader_has_word = false;

        if (reset_mark) {
            buf.get_start_iter (out from);
            buf.move_mark (reader_word_mark, from);
        }
    }

    // scroll_to_mark, not scroll_to_iter: it survives the hop out of a
    // timeout and lets GTK defer until layout is valid. use_align=false
    // with a small margin nudges the word into view instead of recentring
    // the page on every word (KTD4).
    private void scroll_to_current_word () {
        if (!reader_has_word)
            return;
        reader_text_view.scroll_to_mark (reader_word_mark, 0.1, false, 0.0, 0.0);
    }

    // Shown again after close-to-tray or an unmap: the word is still
    // current but the viewport is not (R9, AE5). The idle hop waits for
    // layout, which map alone does not guarantee.
    private void on_reader_text_view_mapped () {
        if (!reader_has_word)
            return;
        Idle.add (() => {
            scroll_to_current_word ();
            return false;
        });
    }

    // CSS cannot colour a range inside a buffer, so the tag copies the
    // themed accent pair and re-copies it on light/dark, high-contrast and
    // accent changes — including while paused, when nothing else repaints.
    // get_style_context () is deprecated in GTK 4.10, but GTK4 offers no
    // other way to resolve a stylesheet-named colour.
    private void apply_word_tag_colors () {
        var context = reader_text_view.get_style_context ();
        Gdk.RGBA rgba;
        if (context.lookup_color ("accent_bg_color", out rgba))
            reader_word_tag.background_rgba = rgba;
        if (context.lookup_color ("accent_fg_color", out rgba))
            reader_word_tag.foreground_rgba = rgba;
    }

    private void on_player_error (string message) {
        reader_status_label.visible = false;
        toast_overlay.add_toast (new Adw.Toast (message));
        update_reader_transport_ui ();
    }

    private void update_reader_transport_ui () {
        bool on_content = reader_on_content_page ();
        if (reader_start_from_here_action != null)
            reader_start_from_here_action.set_enabled (on_content);
        if (!on_content) {
            reader_play_btn.visible = true;
            reader_play_btn.sensitive = false;
            reader_pause_btn.visible = false;
            reader_stop_btn.sensitive = false;
            // Speed menu stays usable on empty / downloading / no-voice.
            sync_mpris ();
            return;
        }

        reader_play_btn.visible = !player.is_playing;
        reader_play_btn.sensitive = true;
        reader_pause_btn.visible = player.is_playing;
        reader_stop_btn.sensitive = (player.is_playing || player.is_paused);
        sync_mpris ();
    }

    public override void dispose () {
        player.shutdown ();
        if (test_close_timeout_id != 0) {
            GLib.Source.remove (test_close_timeout_id);
            test_close_timeout_id = 0;
        }
        if (start_timeout_id != 0) {
            GLib.Source.remove (start_timeout_id);
            start_timeout_id = 0;
        }
        hud.hide ();
        base.dispose ();
    }
}