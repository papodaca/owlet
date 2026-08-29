/* speech-player.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Speech player service that coordinates local neural TTS synthesis
 * (sherpa-onnx) with streaming GStreamer playback (appsrc -> audioconvert
 * -> audioresample -> autoaudiosink / OWLET_TTS_SINK).
 *
 * Features:
 *   - Streaming per-sentence synthesis on a background worker thread
 *   - Sentence-index position tracking (KTD-3)
 *   - Play / Pause / Resume / Stop transport controls
 *   - In-flight bounds: pause holds the pipeline (remaining audio + at most
 *     one blocked next sentence); stop resets to 0

 *   - Lazy engine initialization, held strongly across play invocations
 *   - Word clock: buffers are stamped with accumulating PTS and each
 *     sentence's estimated span table is registered in its PTS window, so
 *     polling pipeline TIME says which word is being spoken (KTD2)
 */

using Gst;

public enum Owlet.PlayerState {
    STOPPED,
    PLAYING,
    PAUSED;

    public unowned string token () {
        switch (this) {
        case STOPPED: return "stopped";
        case PLAYING: return "playing";
        case PAUSED: return "paused";
        default: assert_not_reached ();
        }
    }
}

public class Owlet.SpeechPlayer : GLib.Object {
    public PlayerState state { get; private set; default = PlayerState.STOPPED; }
    public int current_sentence_index { get; private set; default = 0; }
    public int total_sentences { get; private set; default = 0; }

    public bool is_playing { get { return state == PlayerState.PLAYING; } }
    public bool is_paused  { get { return state == PlayerState.PAUSED; } }
    public bool is_stopped { get { return state == PlayerState.STOPPED; } }

    public const float[] SPEED_PRESETS = { 0.75f, 1.0f, 1.25f, 1.5f, 2.0f };

    public signal void position_changed (int sentence_index, int total);
    public signal void playback_started ();
    public signal void playback_stopped (bool natural_end);
    public signal void error_occurred (string message);
    public signal void speed_applied (int sentence_index, float speed);

    /* The word being spoken right now, as 0-based sentence index plus the
     * span's 0-based index and its character offsets inside that sentence
     * (KTD3 — the window maps them onto the joined display buffer).
     * `word_index` is -1 when the speaking sentence has no highlightable
     * span, which asks the reader to drop the tag rather than hold the
     * previous sentence's word. Unlike `position_changed`, the sentence
     * index here is 0-based and matches `play (start_index)`.
     */
    public signal void word_changed (int sentence_index,
                                     int word_index,
                                     int start_offset,
                                     int end_offset);

    public static uint snap_speed_index (float speed) {
        int best_i = 0;
        float best_dist = Math.fabsf (speed - SPEED_PRESETS[0]);
        for (int i = 1; i < SPEED_PRESETS.length; i++) {
            float dist = Math.fabsf (speed - SPEED_PRESETS[i]);
            if (dist < best_dist) {
                best_i = i;
                best_dist = dist;
            }
        }
        return (uint) best_i;
    }

    public static float snap_speed (float speed) {
        return SPEED_PRESETS[snap_speed_index (speed)];
    }

    // Does not restart playback; the next not-yet-generated sentence uses the new rate.
    public void set_speed (float speed) {
        _current_speed = snap_speed (speed);
    }

    // Does not restart playback; the next not-yet-generated sentence uses the new speaker.
    public void set_sid (int sid) {
        _current_sid = sid;
    }

    private SherpaOnnx.OfflineTts? _engine = null;
    private string? _cached_voice_dir = null;

    private Pipeline? _pipeline = null;
    private App.Src? _appsrc = null;
    private uint _bus_watch_id = 0;

    private Thread<void*>? _worker = null;
    private bool _cancel_worker = false;
    private Mutex _worker_mutex;
    private Cond _worker_cond;

    private Owlet.Document? _current_doc = null;
    private string _current_voice_dir = "";
    private int _current_sid = 1;
    private float _current_speed = 1.0f;
    private int _synth_index = 0;

    // Sample rate of the pipeline caps, cached so the worker thread can
    // size buffer timestamps without touching the engine.
    private int _sample_rate = 0;

    // Word clock (KTD2). Buffers carry accumulating PTS; each pushed
    // sentence's span table is registered against the window it occupies.
    private const uint WORD_CLOCK_INTERVAL_MS = 50;

    private class SentenceWindow : GLib.Object {
        public int sentence_index;
        public int64 pts_start;
        public int64 pts_end;
        public Owlet.WordSpan[] spans;

        public SentenceWindow (int sentence_index, int64 pts_start, int64 pts_end,
                               owned Owlet.WordSpan[] spans) {
            this.sentence_index = sentence_index;
            this.pts_start = pts_start;
            this.pts_end = pts_end;
            this.spans = (owned) spans;
        }
    }

    private int64 _pts_accum = 0;
    private SentenceWindow[] _windows = {};
    private uint _word_clock_id = 0;
    // Bumped by every play / stop, so an Idle registration queued by the
    // previous listen cannot land on the new pipeline's timeline.
    private int _listen_generation = 0;
    private int _last_word_sentence = -1;
    private int _last_word_index = -1;
    private bool _shut_down = false;

    private static bool _gst_inited = false;

    construct {
        _worker_mutex = Mutex ();
        _worker_cond = Cond ();
    }

    private static void ensure_gst_init () {
        if (_gst_inited)
            return;
        try {
            unowned string[]? args = null;
            Gst.init_check (ref args);
            _gst_inited = true;
        } catch (Error e) {
            // best effort
        }
    }

    public void invalidate_engine () {
        _engine = null;
        _cached_voice_dir = null;
    }

    private bool ensure_engine (string voice_dir) {
        if (_engine != null && _cached_voice_dir == voice_dir) {
            return true;
        }

        _engine = null;
        _cached_voice_dir = null;

        string model_path = Path.build_filename (voice_dir, "model.onnx");
        string voices_path = Path.build_filename (voice_dir, "voices.bin");
        string tokens_path = Path.build_filename (voice_dir, "tokens.txt");
        string data_dir_path = Path.build_filename (voice_dir, "espeak-ng-data");

        SherpaOnnx.OfflineTtsConfig config = {};
        config.model.kokoro.model = model_path;
        config.model.kokoro.voices = voices_path;
        config.model.kokoro.tokens = tokens_path;
        config.model.kokoro.data_dir = data_dir_path;
        config.model.kokoro.length_scale = 1.0f;
        config.model.num_threads = 2;
        config.model.provider = "cpu";
        config.model.debug = 0;

        _engine = SherpaOnnx.OfflineTts.create (ref config);
        if (_engine == null) {
            string msg = _("Failed to initialize speech synthesis engine from %s").printf (voice_dir);
            Idle.add (() => {
                error_occurred (msg);
                return false;
            });
            return false;
        }

        _cached_voice_dir = voice_dir;
        return true;
    }

    public void play (Owlet.Document document,
                      string voice_dir,
                      int start_index = 0,
                      int sid = 1,
                      float speed = 1.0f) {
        if (document.status != Owlet.DocumentStatus.OK || document.sentences.length == 0) {
            Idle.add (() => {
                error_occurred (_("Document has no readable text"));
                return false;
            });
            return;
        }

        stop_internal (false);
        // Join any leftover generate before replacing the engine or appsrc.
        stop_worker ();

        if (!ensure_engine (voice_dir)) {
            return;
        }

        _current_doc = document;
        _current_voice_dir = voice_dir;
        _current_sid = sid;
        _current_speed = snap_speed (speed);
        total_sentences = document.sentences.length;
        current_sentence_index = (start_index >= 0 && start_index < total_sentences) ? start_index : 0;
        _synth_index = current_sentence_index;
        _sample_rate = _engine.sample_rate ();
        // A new listen starts a fresh timeline; the internal stop above
        // emits no signal, so this is also where the reader's cached
        // offsets stop matching anything (R4).
        reset_word_clock ();

        if (!setup_pipeline (_sample_rate)) {
            return;
        }

        state = PlayerState.PLAYING;
        playback_started ();

        start_word_clock ();
        start_worker ();
    }

    public void pause () {
        if (state != PlayerState.PLAYING) {
            return;
        }

        // Keep the sink's remaining PCM and the worker's blocked next
        // sentence. Resume drains those, then synthesis continues.
        stop_word_clock ();
        if (_pipeline != null) {
            _pipeline.set_state (State.PAUSED);
        }
        state = PlayerState.PAUSED;
    }

    public void resume () {
        if (state != PlayerState.PAUSED || _current_doc == null) {
            return;
        }

        if (_pipeline == null) {
            error_occurred (_("TTS playback pipeline is not available"));
            return;
        }

        var ret = _pipeline.set_state (State.PLAYING);
        if (ret == StateChangeReturn.FAILURE) {
            error_occurred (_("Failed to resume TTS playback"));
            return;
        }

        state = PlayerState.PLAYING;
        // Resume keeps the word the pause froze: the clock restarts, but
        // the last emitted span is remembered, so nothing repaints until
        // the spoken word actually changes (KTD2, R3).
        start_word_clock ();
        playback_started ();
    }

    public void stop () {
        stop_internal (true);
    }

    private void stop_internal (bool emit_signal) {
        // Before halt, so a queued tick cannot paint after teardown.
        reset_word_clock ();
        halt_pipeline ();

        bool was_active = (state != PlayerState.STOPPED);
        state = PlayerState.STOPPED;
        current_sentence_index = 0;
        total_sentences = 0;
        _current_doc = null;

        if (emit_signal && was_active) {
            playback_stopped (false);
        }
    }

    private void start_word_clock () {
        if (_word_clock_id != 0) {
            return;
        }
        _word_clock_id = Timeout.add (WORD_CLOCK_INTERVAL_MS, on_word_clock_tick);
    }

    private void stop_word_clock () {
        if (_word_clock_id != 0) {
            Source.remove (_word_clock_id);
            _word_clock_id = 0;
        }
    }

    private void reset_word_clock () {
        stop_word_clock ();
        _listen_generation++;
        _windows = {};
        _pts_accum = 0;
        _last_word_sentence = -1;
        _last_word_index = -1;
    }

    // Poll pipeline TIME rather than deriving position from generate
    // progress: `position_changed` fires when a sentence is queued, which
    // is ahead of its audio. The period is wall-clock and is never scaled
    // by the generate speed, because that speed is already baked into the
    // sample counts the PTS windows are built from.
    private bool on_word_clock_tick () {
        if (state != PlayerState.PLAYING || _pipeline == null) {
            return true;
        }

        int64 position;
        if (!_pipeline.query_position (Gst.Format.TIME, out position)) {
            // Preroll, or a mid-sentence hiccup. Hold the last word; do
            // not interpolate from wall clock.
            return true;
        }

        prune_windows (position);
        SentenceWindow? window = window_for (position);
        if (window == null) {
            return true;
        }

        if (window.spans.length == 0) {
            emit_word (window.sentence_index, -1, 0, 0);
            return true;
        }

        double elapsed = (double) (position - window.pts_start) / Gst.SECOND;
        int index = window.spans.length - 1;
        for (int i = 0; i < window.spans.length; i++) {
            if (elapsed < window.spans[i].t1) {
                index = i;
                break;
            }
        }
        emit_word (window.sentence_index, index,
                   window.spans[index].start, window.spans[index].end);
        return true;
    }

    private void emit_word (int sentence_index, int word_index, int start, int end) {
        if (_last_word_sentence == sentence_index && _last_word_index == word_index) {
            return;
        }
        _last_word_sentence = sentence_index;
        _last_word_index = word_index;
        word_changed (sentence_index, word_index, start, end);
    }

    // Drop windows the playhead has passed, but never the newest one: a
    // position past the end of the last buffer keeps its final word.
    private void prune_windows (int64 position) {
        if (_windows.length <= 1) {
            return;
        }
        SentenceWindow[] live = {};
        for (int i = 0; i < _windows.length; i++) {
            if (_windows[i].pts_end > position || i == _windows.length - 1) {
                live += _windows[i];
            }
        }
        _windows = live;
    }

    private SentenceWindow? window_for (int64 position) {
        foreach (unowned SentenceWindow window in _windows) {
            if (position >= window.pts_start && position < window.pts_end) {
                return window;
            }
        }
        return null;
    }

    private bool setup_pipeline (int sample_rate) {
        ensure_gst_init ();
        teardown_pipeline ();

        var pipeline = new Pipeline ("owlet-tts-player");
        _pipeline = pipeline;

        var src = (App.Src) ElementFactory.make ("appsrc", "src");
        if (src == null) {
            error_occurred (_("Failed to create GStreamer appsrc"));
            teardown_pipeline ();
            return false;
        }

        src.set_property ("format", Format.TIME);
        src.set_property ("is-live", false);
        src.set_property ("block", true);
        // One in-flight sentence: the next push blocks until the sink
        // drains (pause leaves that buffer in place; stop tears down).
        src.set_property ("max-buffers", 1u);
        src.set_caps (Caps.from_string (
            "audio/x-raw, format=F32LE, channels=1, rate=%d, layout=interleaved".printf (sample_rate)));
        _appsrc = src;

        var convert  = ElementFactory.make ("audioconvert", "convert");
        var resample = ElementFactory.make ("audioresample", "resample");

        string? sink_override = Environment.get_variable ("OWLET_TTS_SINK");
        Element? sink = null;
        if (sink_override != null && sink_override != "") {
            sink = ElementFactory.make (sink_override, "sink");
            if (sink_override == "fakesink" && sink != null) {
                sink.set_property ("sync", true);
            }
        }
        if (sink == null) {
            sink = ElementFactory.make ("autoaudiosink", "sink");
        }
        if (sink == null) {
            sink = ElementFactory.make ("fakesink", "sink");
        }

        pipeline.add_many (src, convert, resample, sink);
        if (!src.link_many (convert, resample, sink)) {
            error_occurred (_("Failed to link TTS playback pipeline"));
            teardown_pipeline ();
            return false;
        }

        var bus = pipeline.get_bus ();
        _bus_watch_id = bus.add_watch (GLib.Priority.DEFAULT, on_bus_message);

        var ret = pipeline.set_state (State.PLAYING);
        if (ret == StateChangeReturn.FAILURE) {
            error_occurred (_("Failed to start TTS playback pipeline"));
            teardown_pipeline ();
            return false;
        }

        return true;
    }

    private void teardown_pipeline () {
        stop_word_clock ();
        if (_bus_watch_id != 0) {
            Source.remove (_bus_watch_id);
            _bus_watch_id = 0;
        }
        if (_pipeline != null) {
            _pipeline.set_state (State.NULL);
            _pipeline = null;
            _appsrc = null;
        }
    }

    private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
        switch (message.type) {
        case MessageType.EOS:
            Idle.add (() => {
                if (state == PlayerState.PLAYING) {
                    stop_internal (false);
                    playback_stopped (true);
                }
                return false;
            });
            break;
        case MessageType.ERROR:
            GLib.Error err;
            string debug;
            message.parse_error (out err, out debug);
            Idle.add (() => {
                error_occurred (_("Audio playback error: %s").printf (err.message));
                stop_internal (true);
                return false;
            });
            break;
        default:
            break;
        }
        return true;
    }

    // Stop audio immediately. appsrc is blocking with max-buffers=1, so the
    // worker may be sitting in push_buffer until the sink drains — unlocking
    // and going to NULL wakes that wait. Join happens later (play / dispose)
    // so Stop is not delayed by the rest of the sentence. Pause uses PAUSED
    // instead, to keep the in-flight buffer.
    private void halt_pipeline () {
        _cancel_worker = true;
        if (_bus_watch_id != 0) {
            Source.remove (_bus_watch_id);
            _bus_watch_id = 0;
        }
        if (_appsrc != null) {
            _appsrc.set_property ("block", false);
        }
        if (_pipeline != null) {
            _pipeline.send_event (new Event.flush_start ());
            _pipeline.set_state (State.NULL);
        }
    }

    private void start_worker () {
        stop_worker ();
        _cancel_worker = false;
        try {
            _worker = new Thread<void*> ("tts-worker", worker_func);
        } catch (Error e) {
            error_occurred (_("Failed to start synthesis worker thread: %s").printf (e.message));
        }
    }

    private void stop_worker () {
        _cancel_worker = true;
        if (_worker != null) {
            _worker.join ();
            _worker = null;
        }
    }

    private void* worker_func () {
        while (!_cancel_worker && _current_doc != null) {
            int idx = _synth_index;
            if (idx >= _current_doc.sentences.length) {
                if (_appsrc != null) {
                    _appsrc.end_of_stream ();
                }
                break;
            }

            string sentence_text = _current_doc.sentences[idx];
            int sid = _current_sid;
            float speed = _current_speed;
            int sent_idx = idx + 1;
            int total = total_sentences;
            Idle.add (() => {
                if (state == PlayerState.PLAYING) {
                    speed_applied (sent_idx, speed);
                }
                return false;
            });

            SherpaOnnx.GeneratedAudio? audio = null;
            if (_engine != null) {
                audio = _engine.generate_with_progress_callback (
                    sentence_text, sid, speed, (samples, progress) => {
                        return _cancel_worker ? 0 : 1;
                    }
                );
            }

            if (_cancel_worker) {
                break;
            }

            if (audio == null) {
                Idle.add (() => {
                    error_occurred (_("Speech synthesis failed on sentence %d").printf (idx + 1));
                    stop_internal (true);
                    return false;
                });
                break;
            }

            // A zero-sample sentence is skipped without advancing PTS, so
            // it never gets a window and never invents a word.
            if (audio.n > 0 && _appsrc != null && !_cancel_worker) {
                uint8[] bytes = new uint8[audio.n * sizeof (float)];
                Posix.memcpy (bytes, audio.samples, bytes.length);

                int64 pts = _pts_accum;
                int64 span = 0;
                Owlet.WordSpan[] spans = {};
                // The pipeline negotiated caps at this rate, so it is
                // positive; the guard only stops a broken engine from
                // dividing by zero.
                if (_sample_rate > 0) {
                    span = (int64) audio.n * Gst.SECOND / _sample_rate;
                    spans = Owlet.WordSpans.estimate (
                        sentence_text, (double) audio.n / _sample_rate);
                }

                var buf = new Gst.Buffer.wrapped ((owned) bytes);
                buf.pts = (Gst.ClockTime) pts;
                buf.duration = (Gst.ClockTime) span;

                var flow = _appsrc.push_buffer (buf);
                if (flow != FlowReturn.OK && flow != FlowReturn.FLUSHING) {
                    break;
                }
                if (flow == FlowReturn.OK && !_cancel_worker) {
                    _pts_accum = pts + span;
                    // Register after the push is accepted, on the GTK
                    // thread. Windows are appended, never replaced, so the
                    // table currently being clocked survives the arrival of
                    // the next sentence's table.
                    int generation = _listen_generation;
                    var window = new SentenceWindow (idx, pts, pts + span,
                                                     (owned) spans);
                    Idle.add (() => {
                        if (_listen_generation == generation) {
                            _windows += window;
                        }
                        return false;
                    });
                }
            }

            if (_cancel_worker) {
                break;
            }

            _synth_index = idx + 1;

            Idle.add (() => {
                if (state == PlayerState.PLAYING) {
                    current_sentence_index = sent_idx;
                    position_changed (sent_idx, total);
                }
                return false;
            });
        }
        return null;
    }

    // Join the synth worker and drop the pipeline. Idempotent so Quit
    // can run this before gtk_window_destroy, which also disposes us.
    // Unblock appsrc before joining so a paused/playing push_buffer
    // wait cannot deadlock set_state(NULL).
    public void shutdown () {
        if (_shut_down)
            return;
        _shut_down = true;
        reset_word_clock ();
        _cancel_worker = true;
        if (_appsrc != null)
            _appsrc.set_property ("block", false);
        if (_pipeline != null)
            _pipeline.send_event (new Event.flush_start ());
        stop_worker ();
        teardown_pipeline ();
        invalidate_engine ();
        _current_doc = null;
        state = PlayerState.STOPPED;
    }

    public override void dispose () {
        shutdown ();
        base.dispose ();
    }
}
